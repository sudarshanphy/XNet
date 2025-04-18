!***************************************************************************************************
! net.f90 10/18/17
! This program is a driver to run XNet (on multiple processors if using MPI, by allocating successive
! zones to each processor).
!
! This driver reads in the controlling flags, the nuclear and reaction data. It also loops through
! reading the initial abundances and the thermodynamic trajectory before calling full_net for each
! zone.
!
! If you wish to use full_net in concert with a hydrodynmics code, you will need to supply these
! services from within the hydro.
!***************************************************************************************************

#include "xnet_macros.fh"

Program net
  !-------------------------------------------------------------------------------------------------
  ! This is the driver for running XNet
  !-------------------------------------------------------------------------------------------------
  Use nuclear_data, Only: ny, aa, zz, nname, index_from_name, read_nuclear_data
!$ Use omp_lib
  Use xnet_parallel, Only: parallel_finalize, parallel_initialize, parallel_myproc, parallel_nprocs, &
    & parallel_IOProcessor
  Use reaction_data, Only: read_reaction_data
  Use xnet_abundances, Only: ystart, yo, y, yt, ydot, xext, zext, aext
  Use xnet_conditions, Only: t, tt, to, tdel, tdel_next, tdel_old, t9t, rhot, yet, t9, rho, ye, &
    & t9o, rhoo, yeo, t9dot, cv, etae, detaedt9, nt, ntt, nto, ints, intso, nstart, tstart, tstop, &
    & tdelstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh, nhmx, t9rhofind
  Use xnet_controls, Only: descript, iconvc, idiag, iheat, inucout, iprocess, iscrn, isolv, &
    & itsout, iweak0, nnucout, nnucout_string, output_nuc, szone, nzone, zone_id, changemx, tolm, tolc, &
    & yacc, ymin, tdel_maxmult, kstmx, kitmx, ev_file_base, bin_file_base, thermo_file, inab_file, &
    & lun_diag, lun_ev, lun_stdout, lun_ts, tid, nthread, nzevolve, nzbatchmx, nzbatch, szbatch, &
    & zb_offset, zb_lo, zb_hi, lzactive, myid, nproc, read_controls, write_controls, iaux
  Use xnet_eos, Only: eos_initialize
  Use xnet_evolve, Only: full_net
  Use xnet_flux, Only: flx_int, ifl_orig, ifl_term, flux_init
  Use xnet_gpu, Only: gpu_init, gpu_finalize
  Use xnet_integrate_bdf, Only: bdf_init
  Use xnet_integrate_be, Only: be_init
  Use xnet_jacobian, Only: read_jacobian_data
  Use xnet_match, Only: mflx, nflx, read_match_data
  Use xnet_nnu, Only: nnuspec, tmevnu, fluxcms
  Use xnet_nse, Only: nse_initialize
  Use xnet_preprocess, Only: net_preprocess
  Use xnet_screening, Only: screening_init
  Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_setup
  Use xnet_types, Only: dp
  Use xnet_util, Only: name_ordered
  Use model_input_ascii
  Implicit None

  ! Local variables
  Integer :: i, k, izone ! Loop indices
  Integer :: ierr, inuc
  Integer :: ibatch, batch_count, izb
  Integer :: kstep

  ! Thermodynamic input data
  Real(dp), Allocatable :: dyf(:), flx_diff(:)

  ! Neutrino loss data
  Real(dp), Allocatable :: denu(:)

  ! Input Data descriptions
  Character(80) :: data_desc, data_dir
  Character(80), Allocatable :: abund_desc(:), thermo_desc(:)

  ! Filenames
  Character(80) :: ev_file, bin_file, diag_file
  Character(80) :: diag_file_base = 'net_diag'
  Character(25) :: ev_header_format

  ! Identify number of MPI nodes and ID number for this PE
  Call parallel_initialize()
  myid = parallel_myproc()
  nproc = parallel_nprocs()

  ! Identify threads
  !$omp parallel default(shared)
  tid = 1
  !$ tid = omp_get_thread_num() + 1
  !$omp single
  nthread = 1
  !$ nthread = omp_get_num_threads()
  !$omp end single
  !$omp end parallel

  Call gpu_init()

  start_timer = xnet_wtime()
  timer_setup = timer_setup - start_timer

  ! Read and distribute user-defined controls
  Call read_controls(data_dir)

  ! If requested, pre-process the nuclear and reaction data.
  IF ( iprocess > 0 .and. parallel_IOProcessor() ) CALL net_preprocess( lun_stdout, data_dir, data_dir )

  !-------------------------------------------------------------------------------------------------
  ! Output files:
  ! The diagnostic output is per thread
  ! General output is per zone
  !-------------------------------------------------------------------------------------------------

  ! Open diagnositic output file, per thread if OMP
  !$omp parallel default(shared) private(diag_file)
  If ( idiag >= 0 ) Then
    diag_file = trim(diag_file_base)
    Call name_ordered(diag_file,myid,nproc)
    Call name_ordered(diag_file,tid,nthread)
    Open(newunit=lun_diag, file=diag_file, action='write')
    Write(lun_diag,"(a5,2i5)") 'MyId',myid,nproc
    !$ Write(lun_diag,"(a,i4,a,i4)") 'Thread ',tid,' of ',nthread
  Else
    lun_diag = lun_stdout
  EndIf
  Call write_controls(lun_diag,data_dir)
  !$omp end parallel

  ! Read and distribute nuclear and reaction data
  Call read_nuclear_data(data_dir,data_desc)
  Call read_reaction_data(data_dir)
  If ( idiag >= 0 ) Write(lun_diag,"(a)") data_desc

  ! Read and distribute jacobian matrix data
  Call read_jacobian_data(data_dir)

  ! Read data on matching forward and reverse reactions
  Call read_match_data(data_dir)

  ! Initialize screening
  Call screening_init

  ! Initialize flux tracking
  Call flux_init

  ! Initialize EoS for screening or self-heating
  Call eos_initialize

  If ( isolv == 1 ) Call be_init
  If ( isolv == 3 ) Call bdf_init

  ! Convert output_nuc names into indices
  Do i = 1, nnucout
    Call index_from_name(output_nuc(i),inuc)
    If ( inuc < 1 .or. inuc > ny ) Then
      Write(lun_stdout,*) 'Output Nuc:',i,output_nuc(i),' not found'
      inucout(i) = ny
    Else
      inucout(i) = inuc
    EndIf
  EndDo

  ! Initialize NSE
  Call nse_initialize

  ! This is essentially a ceiling function for integer division
  batch_count = (nzone + nzbatchmx - 1) / nzbatchmx

  ! Set sizes of abundance arrays
  Allocate (y(ny,nzevolve),yo(ny,nzevolve),yt(ny,nzevolve),ydot(ny,nzevolve),ystart(ny,nzevolve))
  Allocate (xext(nzevolve),aext(nzevolve),zext(nzevolve),iaux(nzevolve))
  y = 0.0 ; yo = 0.0 ; yt = 0.0 ; ydot = 0.0 ; ystart = 0.0
  xext = 0.0 ; aext = 0.0 ; zext = 0.0 ; iaux = 0

  ! Allocate conditions arrays
  Allocate (tdel(nzevolve),tdel_next(nzevolve),tdel_old(nzevolve), &
    &       t(nzevolve),tt(nzevolve),to(nzevolve), &
    &       t9(nzevolve),t9t(nzevolve),t9o(nzevolve),t9dot(nzevolve), &
    &       rho(nzevolve),rhot(nzevolve),rhoo(nzevolve), &
    &       ye(nzevolve),yet(nzevolve),yeo(nzevolve), &
    &       cv(nzevolve),etae(nzevolve),detaedt9(nzevolve), &
    &       nt(nzevolve),ntt(nzevolve),nto(nzevolve), &
    &       ints(nzevolve),intso(nzevolve))
  tdel  = 0.0 ; tdel_next = 0.0 ; tdel_old = 0.0
  t     = 0.0 ; tt        = 0.0 ; to       = 0.0
  t9    = 0.0 ; t9t       = 0.0 ; t9o      = 0.0 ; t9dot = 0.0
  rho   = 0.0 ; rhot      = 0.0 ; rhoo     = 0.0
  ye    = 0.0 ; yet       = 0.0 ; yeo      = 0.0
  cv    = 0.0 ; etae      = 0.0 ; detaedt9 = 0.0
  nt    = 0   ; ntt       = 0   ; nto      = 0
  ints  = 0   ; intso     = 0

  ! Allocate thermo history arrays
  Allocate (nstart(nzevolve),tstart(nzevolve),tstop(nzevolve),tdelstart(nzevolve), &
    &       t9start(nzevolve),rhostart(nzevolve),yestart(nzevolve), &
    &       nh(nzevolve),th(nhmx,nzevolve),t9h(nhmx,nzevolve),rhoh(nhmx,nzevolve), &
    &       yeh(nhmx,nzevolve),tmevnu(nhmx,nnuspec,nzevolve),fluxcms(nhmx,nnuspec,nzevolve))
  tstart = 0.0 ; tstop   = 0.0 ; tdelstart = 0.0 ; th      = 0.0
  nstart = 0   ; t9start = 0.0 ; rhostart  = 0.0 ; yestart = 0.0
  nh     = 0   ; t9h     = 0.0 ; rhoh      = 0.0 ; yeh     = 0.0
  tmevnu = 0.0 ; fluxcms = 0.0

  ! Allocate zone description arrays
  Allocate (abund_desc(nzevolve),thermo_desc(nzevolve))

  ! Allocate neutrino loss data
  Allocate ( denu(nzevolve) )
  denu = 0.0

  !XDIR XENTER_DATA XASYNC(tid) &
  !XDIR XCOPYIN(y,yo,yt,ydot,ystart,xext,aext,zext) &
  !XDIR XCOPYIN(tdel,tdel_next,tdel_old,t,tt,to,t9,t9t,t9o,t9dot) &
  !XDIR XCOPYIN(rho,rhot,rhoo,ye,yet,yeo,cv,etae,detaedt9,nt,ntt,nto,ints,intso) &
  !XDIR XCOPYIN(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart) &
  !XDIR XCOPYIN(nh,th,t9h,rhoh,yeh,tmevnu,fluxcms) &
  !XDIR XCOPYIN(denu)

  !XDIR XWAIT(tid)

  stop_timer = xnet_wtime()
  timer_setup = timer_setup + stop_timer

  !$omp parallel default(shared) &
  !$omp   private(dyf,flx_diff,ev_file,bin_file,izone,ierr,ibatch,izb,kstep) &
  !$omp   copyin(timer_setup)

  start_timer = xnet_wtime()
  timer_setup = timer_setup - start_timer

  Allocate (dyf(0:ny),flx_diff(ny))

  stop_timer = xnet_wtime()
  timer_setup = timer_setup + stop_timer

  ! Loop over zones in batches, assigning each batch of zones to MPI tasks in order
  !$omp do
  Do ibatch = myid+1, batch_count, nproc

    start_timer = xnet_wtime()
    timer_setup = timer_setup - start_timer

    ! Determine which zones are in this batch
    szbatch = szone + (ibatch-1)*nzbatchmx
    nzbatch = min(nzone-szbatch+1, nzbatchmx)

    ! Active zone mask
    Do izb = zb_lo, zb_hi
      If ( izb <= zb_offset + nzbatch ) Then
        lzactive(izb) = .true.
      Else
        lzactive(izb) = .false.
      EndIf
    EndDo

    ! Read thermodynamic history files
    Call read_thermo_file(thermo_file,thermo_desc,ierr)

    ! Determine thermodynamic conditions at tstart
    Do izb = zb_lo, zb_hi
      If ( lzactive(izb) ) Then
        Call t9rhofind(0,tstart(izb),nstart(izb),t9start(izb),rhostart(izb), &
          & nh(izb),th(:,izb),t9h(:,izb),rhoh(:,izb))
      EndIf
    EndDo

    ! Determine initial abundances
    Call load_initial_abundances(inab_file,abund_desc,ierr)

    ! Load initial abundances, time and timestep
    Do izb = zb_lo, zb_hi
      tdel(izb) = 0.0
      nt(izb)   = nstart(izb)
      t(izb)    = tstart(izb)
      t9(izb)   = t9start(izb)
      rho(izb)  = rhostart(izb)
      ye(izb)   = yestart(izb)
      y(:,izb)  = ystart(:,izb)
      zone_id(1,izb)=izb
      zone_id(2,izb)=1
      zone_id(3,izb)=1
    EndDo

    If ( itsout > 0 ) Then
      Do izb = zb_lo, zb_hi
        If ( lzactive(izb) ) Then
          izone = izb + szbatch - zb_lo
          Write(lun_stdout,"(a,i6,a,i2,2(a,es10.3))") &
            & 'Max Step',kstmx,' IDiag=',idiag, ' Start Time',tstart(izb),' Stop Time',tstop(izb)

          ! Open the binary time series file
          If ( itsout >= 1 ) Then
            bin_file = trim(bin_file_base)
            Call name_ordered(bin_file,izone,nzone)
            Open(newunit=lun_ts(izb), file=bin_file, form='unformatted', action='write')

            ! Write Control Parameters to ts file
            Write(lun_ts(izb)) (descript(i),i=1,3),data_desc
            Write(lun_ts(izb)) kstmx,kitmx,iweak0,iscrn,iconvc,changemx,tolm,tolc,yacc,ymin,tdel_maxmult,iheat,isolv

            ! Write abundance description to ts file
            Write(lun_ts(izb)) inab_file(izone),abund_desc(izb)

            ! Write thermo description to ts file
            Write(lun_ts(izb)) thermo_file(izone),thermo_desc(izb)

            ! Write species identifiers to ts file
            Write(lun_ts(izb)) ny,zz,aa

            ! Write flux identifiers to ts file
            Write(lun_ts(izb)) mflx,ifl_orig,ifl_term
          EndIf

          ! Open the evolution file
          If ( itsout >= 2 ) Then
            ev_file = trim(ev_file_base)
            Call name_ordered(ev_file,izone,nzone)
            If ( idiag >= 0 ) Write(lun_diag,"(a,i5,7es10.3)") trim(ev_file), &
              & nh(izb),th(nh(izb),izb),t9h(nh(izb),izb),rhoh(nh(izb),izb),tstart(izb),tstop(izb)
            Open(newunit=lun_ev(izb), file=ev_file, action='write')

            ! Write evolution file header
            Write(ev_header_format,"(a)") "(a4,a15,5a10,"//trim(nnucout_string)//"a9,a4)"
            Write(lun_ev(izb),ev_header_format) &
              & 'k ',' Time ',' T(GK) ',' Density ',' dE/dt ',' sqnu ',' Timestep ',(nname(inucout(i)),i=1,nnucout), ' It '
          EndIf
        EndIf
      EndDo
    EndIf

    !XDIR XUPDATE XASYNC(tid) &
    !XDIR XDEVICE(xext,aext,zext) &
    !XDIR XDEVICE(lzactive,tdel,t,t9,rho,ye,y,nt) &
    !XDIR XDEVICE(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart,ystart) &
    !XDIR XDEVICE(nh,th,t9h,rhoh,yeh,tmevnu,fluxcms)

    stop_timer = xnet_wtime()
    timer_setup = timer_setup + stop_timer

    ! Evolve abundance from tstart to tstop
    Call full_net(kstep,denu(zb_lo:zb_hi))

    ! Test how well sums of fluxes match abundances changes
    If ( idiag >= 3 ) Then
      !XDIR XUPDATE XWAIT(tid) &
      !XDIR XHOST(y)
      Do izb = zb_lo, zb_hi
        If ( lzactive(izb) ) Then
          dyf = 0.0
          Do k = 1, mflx
            dyf(nflx(1:4,k)) = dyf(nflx(1:4,k)) + flx_int(k,izb)
            dyf(nflx(5:8,k)) = dyf(nflx(5:8,k)) - flx_int(k,izb)
          EndDo
          flx_diff(:) = y(:,izb) - ystart(:,izb) + dyf(1:ny)
          Write(lun_diag,"(a,es11.3)") 'Compare Integrated flux to abundance change',dyf(0)
          Write(lun_diag,"(a)") 'Species Flux Sum + Y Final - Y Initial = Flux Diff'
          Write(lun_diag,"(a5,4es11.3)") (nname(k),dyf(k),y(k,izb),ystart(k,izb),flx_diff(k),k=1,ny)
        EndIf
      EndDo
    EndIf

    ! Close zone output files
    Do izb = zb_lo, zb_hi
      If ( lzactive(izb) ) Then
        If (itsout >= 2 ) Close(lun_ev(izb))
        If (itsout >= 1 ) Close(lun_ts(izb))
      EndIf
    EndDo
  EndDo
  !$omp end do

  ! Close diagnostic output file
  If ( idiag >= 0 ) Close(lun_diag)
  !$omp end parallel

  !XDIR XEXIT_DATA XASYNC(tid) &
  !XDIR XDELETE(y,yo,yt,ydot,ystart,xext,aext,zext) &
  !XDIR XDELETE(tdel,tdel_next,tdel_old,t,tt,to,t9,t9t,t9o,t9dot) &
  !XDIR XDELETE(rho,rhot,rhoo,ye,yet,yeo,cv,etae,detaedt9,nt,ntt,nto,ints,intso) &
  !XDIR XDELETE(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart) &
  !XDIR XDELETE(nh,th,t9h,rhoh,yeh,tmevnu,fluxcms) &
  !XDIR XDELETE(denu)

  !XDIR XWAIT(tid)

  Call gpu_finalize()

  ! Wait for all nodes to finish
  Call parallel_finalize()

End Program net
