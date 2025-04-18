!***************************************************************************************************
! jacobian_dense.f90 10/18/17
! The routines in this file assume a dense Jacobian and use a dense linear algebra package.
!
! The bulk of the computational cost of the network (60-95%) is the solving of the matrix equation.
! Careful selection of the matrix solver is therefore very important to fast computation. For
! networks from a few dozen up to a couple hundred species, hand tuned dense solvers such as those
! supplied by the hardware manufacturer (often LAPACK) or third-parties like NAG, IMSL, etc. are
! fastest. However for larger matrices, sparse solvers are faster.
!*******************************************************************************

#include "xnet_macros.fh"

#if !defined(USE_NOPIVOT)
#define USE_NOPIVOT 0
#endif

Module xnet_jacobian
  !-------------------------------------------------------------------------------------------------
  ! The Jacobian matrix for the solver.
  !-------------------------------------------------------------------------------------------------
  Use, Intrinsic :: iso_c_binding
  Use xnet_types, Only: dp
  Implicit None
  Real(dp), Allocatable, Target :: dydotdy(:,:,:) ! dYdot/dY part of jac
  Real(dp), Allocatable, Target :: jac(:,:,:)     ! the Jacobian matrix
  Real(dp), Allocatable, Target :: rhs(:,:)       ! the Jacobian matrix
  Integer, Allocatable, Target :: indx(:,:)       ! Pivots in the LU decomposition
  Integer, Allocatable, Target :: info(:)

  Type(C_PTR), Allocatable, Target :: hjac(:), hrhs(:), hindx(:)
  Type(C_PTR), Allocatable, Target :: djac(:), drhs(:), dindx(:)

  ! Array size parameters
  Real(C_DOUBLE), Parameter :: ddummy = 0.0
  Integer(C_INT), Parameter :: idummy = 0
  Integer(C_INTPTR_T), Parameter :: cptr_dummy = 0
  Integer(C_SIZE_T), Parameter :: sizeof_double = c_sizeof(ddummy)
  Integer(C_SIZE_T), Parameter :: sizeof_int = c_sizeof(idummy)
  Integer(C_SIZE_T), Parameter :: sizeof_cptr = c_sizeof(cptr_dummy)
  Integer(C_SIZE_T) :: sizeof_jac, sizeof_rhs, sizeof_indx, sizeof_info, sizeof_batch

  ! Parameters for GPU array dimensions
  Integer :: msize ! Size of linear system to be solved

  Real(dp), Allocatable, Target :: diag0(:)
  Real(dp), Allocatable, Target :: mult1(:)

  Real(dp), Parameter :: pivot_thresh = 1.0e-4
  Logical, Allocatable :: pivot(:)

Contains

  Subroutine read_jacobian_data(data_dir)
    !-----------------------------------------------------------------------------------------------
    ! Initializes the Jacobian data.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny
    Use xnet_controls, Only: iheat, nzevolve, tid
    Use xnet_gpu, Only: dev_ptr
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: data_dir

    ! Local variables
    Integer :: izb

    ! Calculate array sizes
    If ( iheat > 0 ) Then
      msize = ny + 1
    Else
      msize = ny
    EndIf

    Allocate (diag0(nzevolve))
    Allocate (mult1(nzevolve))
    Allocate (pivot(nzevolve))
    diag0 = 0.0
    mult1 = 1.0
    pivot = .false.

    Allocate (dydotdy(msize,msize,nzevolve))
    Allocate (jac(msize,msize,nzevolve))
    Allocate (rhs(msize,nzevolve))
    Allocate (indx(msize,nzevolve))
    Allocate (info(nzevolve))
    dydotdy = 0.0
    jac = 0.0
    rhs = 0.0
    indx = 0
    info = 0

    !XDIR XENTER_DATA XASYNC(tid) &
    !XDIR XCOPYIN(dydotdy,jac,rhs,indx,info,diag0,mult1,pivot)

    Allocate (hjac(nzevolve))
    Allocate (hrhs(nzevolve))
    Allocate (hindx(nzevolve))
    Do izb = 1, nzevolve
      hjac(izb) = c_loc( jac(1,1,izb) )
      hrhs(izb) = c_loc( rhs(1,izb) )
      hindx(izb) = c_loc( indx(1,izb) )
    EndDo

    Allocate (djac(nzevolve))
    Allocate (drhs(nzevolve))
    Allocate (dindx(nzevolve))
    Do izb = 1, nzevolve
      djac(izb) = dev_ptr( jac(1,1,izb) )
      drhs(izb) = dev_ptr( rhs(1,izb) )
      dindx(izb) = dev_ptr( indx(1,izb) )
    EndDo

    !XDIR XENTER_DATA XASYNC(tid) &
    !XDIR XCOPYIN(djac,drhs,dindx)

    Return
  End Subroutine read_jacobian_data

  Subroutine jacobian_finalize
    Use xnet_controls, Only: tid
    Implicit None

    !XDIR XEXIT_DATA XASYNC(tid) &
    !XDIR XDELETE(dydotdy,jac,rhs,indx,info,djac,drhs,dindx,diag0,mult1,pivot)

    Deallocate (diag0,mult1,pivot)
    Deallocate (dydotdy,jac,rhs,indx,info)
    Deallocate (hjac,hrhs,hindx)
    Deallocate (djac,drhs,dindx)

    Return
  End Subroutine jacobian_finalize

  Subroutine jacobian_scale(diag_in,mult_in,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! This augments a previously calculation Jacobian matrix by multiplying all elements by mult and
    ! adding diag to the diagonal elements.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, nname
    Use xnet_controls, Only: idiag, iheat, lun_diag, szbatch, zb_lo, zb_hi, lzactive, tid
    Use xnet_types, Only: dp
    Implicit None

    ! Input variables
    Real(dp), Optional, Target, Intent(in) :: diag_in(zb_lo:zb_hi), mult_in(zb_lo:zb_hi)

    ! Optional variables
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Integer :: i, j, i0, j1, izb, izone
    Real(dp) :: rsum
    Real(dp), Pointer :: diag(:), mult(:)
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    If ( present(diag_in) ) Then
      diag(zb_lo:) => diag_in
    Else
      diag(zb_lo:) => diag0(zb_lo:zb_hi)
    EndIf
    If ( present(mult_in) ) Then
      mult(zb_lo:) => mult_in
    Else
      mult(zb_lo:) => mult1(zb_lo:zb_hi)
    EndIf

    !XDIR XENTER_DATA XASYNC(tid) &
    !XDIR XCOPYIN(mask,diag,mult)

    !XDIR XLOOP_OUTER(2) XASYNC(tid) &
    !XDIR XPRESENT(jac,dydotdy,pivot) &
    !XDIR XPRESENT(mask,diag,mult) &
    !XDIR XPRIVATE(rsum)
    Do izb = zb_lo, zb_hi
      Do j1 = 1, msize
        If ( mask(izb) ) Then
          rsum = 0.0
          !XDIR XLOOP_INNER(1) &
          !XDIR XREDUCTION(+,rsum)
          Do i0 = 1, msize
            jac(i0,j1,izb) = mult(izb) * dydotdy(j1,i0,izb)
            If ( i0 == j1 ) Then
              jac(i0,j1,izb) = jac(i0,j1,izb) + diag(izb)
            Else
              rsum = rsum + abs(jac(i0,j1,izb))
            EndIf
          EndDo
          pivot(izb) = ( rsum*pivot_thresh > abs(jac(j1,j1,izb)) )
        EndIf
      EndDo
    EndDo
    !XDIR XUPDATE XASYNC(tid) &
    !XDIR XHOST(pivot)

    If ( idiag >= 3 ) Then
      !XDIR XUPDATE XWAIT(tid) &
      !XDIR XHOST(pivot,jac)
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo
          If ( pivot(izb) ) Then
            Do j = 1, msize
              rsum = 0.0
              Do i = 1, msize
                If ( i /= j ) Then
                  rsum = rsum + abs(jac(j,j,izb))
                EndIf
              EndDo
              i = maxloc(abs(jac(:,j,izb)),dim=1)
              If ( i /= j ) Then
                Write(lun_diag,"(a,2i5,3es24.16)") 'JAC_DIAG',i,j,jac(j,j,izb),jac(i,j,izb),rsum
              EndIf
            EndDo
          EndIf
        EndIf
      EndDo
    EndIf

    If ( idiag >= 5 ) Then
      !XDIR XUPDATE XWAIT(tid) &
      !XDIR XHOST(diag,mult,jac)
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo
          Write(lun_diag,"(a9,i5,2es24.16)") 'JAC_SCALE',izone,diag(izb),mult(izb)
          Do i = 1, ny
            Write(lun_diag,"(3a)") 'J(',nname(i),',Y)'
            Write(lun_diag,"(7es24.16)") (jac(i,j,izb),j=1,ny)
          EndDo
          If ( iheat > 0 ) Then
            Write(lun_diag,"(3a)") 'J(Y,T9)'
            Write(lun_diag,"(7es24.16)") (jac(i,ny+1,izb),i=1,ny)
            Write(lun_diag,"(a)") 'J(T9,Y)'
            Write(lun_diag,"(7es24.16)") (jac(ny+1,j,izb),j=1,ny)
            Write(lun_diag,"(a)") 'J(T9,T9)'
            Write(lun_diag,"(es24.16)") jac(ny+1,ny+1,izb)
          EndIf
        EndIf
      EndDo
    EndIf

    !XDIR XEXIT_DATA XASYNC(tid) &
    !XDIR XDELETE(mask,diag,mult)
    
    Return
  End Subroutine jacobian_scale

  Subroutine jacobian_build(diag_in,mult_in,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! This routine calculates the reaction Jacobian matrix, dYdot/dY, and augments by multiplying
    ! all elements by mult and adding diag to the diagonal elements.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, mex, nname
    Use reaction_data, Only: a1, a2, a3, a4, b1, b2, b3, b4, la, le, mu1, mu2, mu3, mu4, n11, n21, &
      & n22, n31, n32, n33, n41, n42, n43, n44, dcsect1dt9, dcsect2dt9, dcsect3dt9, dcsect4dt9, nan, &
      & n10, n20, n30, n40
    Use xnet_abundances, Only: yt
    Use xnet_conditions, Only: cv
    Use xnet_controls, Only: iheat, idiag, ktot, lun_diag, nzbatchmx, szbatch, zb_lo, zb_hi, &
      & lzactive, tid
    Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_jacob
    Use xnet_types, Only: dp
    Implicit None

    ! Optional variables
    Real(dp), Optional, Target, Intent(in) :: diag_in(zb_lo:zb_hi), mult_in(zb_lo:zb_hi)
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Integer :: i, j, i0, j1, izb, izone
    Real(dp) :: s1, s2, s3, s4, sdot
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    start_timer = xnet_wtime()
    timer_jacob = timer_jacob - start_timer

    !XDIR XENTER_DATA XASYNC(tid) &
    !XDIR XCOPYIN(mask)

    ! Build the Jacobian
    !XDIR XLOOP_OUTER(2) XASYNC(tid) &
    !XDIR XPRIVATE(s1,s2,s3,s4) &
    !XDIR XPRESENT(mask,dydotdy,yt,b1,b2,b3,b4,la,le,cv,mex) &
    !XDIR XPRESENT(n10,n11,n20,n21,n22,n30,n31,n32,n33,n40,n41,n42,n43,n44) &
    !XDIR XPRESENT(mu1,mu2,mu3,mu4,a1,a2,a3,a4) &
    !XDIR XPRESENT(b1,b2,b3,b4,dcsect1dt9,dcsect2dt9,dcsect3dt9,dcsect4dt9)
    Do izb = zb_lo, zb_hi
      Do i0 = 1, ny
        If ( mask(izb) ) Then
          !XDIR XLOOP_INNER(1)
          Do j1 = 1, msize
            dydotdy(j1,i0,izb) = 0.0
          EndDo
          !XDIR XLOOP_INNER(1)
          Do j1 = la(1,i0), le(1,i0)
            !XDIR XATOMIC
            dydotdy(n11(j1),i0,izb) = dydotdy(n11(j1),i0,izb) + b1(j1,izb)
          EndDo
          !XDIR XLOOP_INNER(1)
          Do j1 = la(2,i0), le(2,i0)
            !XDIR XATOMIC
            dydotdy(n21(j1),i0,izb) = dydotdy(n21(j1),i0,izb) + b2(j1,izb) * yt(n22(j1),izb)
            !XDIR XATOMIC
            dydotdy(n22(j1),i0,izb) = dydotdy(n22(j1),i0,izb) + b2(j1,izb) * yt(n21(j1),izb)
          EndDo
          !XDIR XLOOP_INNER(1)
          Do j1 = la(3,i0), le(3,i0)
            !XDIR XATOMIC
            dydotdy(n31(j1),i0,izb) = dydotdy(n31(j1),i0,izb) + b3(j1,izb) * yt(n32(j1),izb) * yt(n33(j1),izb)
            !XDIR XATOMIC
            dydotdy(n32(j1),i0,izb) = dydotdy(n32(j1),i0,izb) + b3(j1,izb) * yt(n33(j1),izb) * yt(n31(j1),izb)
            !XDIR XATOMIC
            dydotdy(n33(j1),i0,izb) = dydotdy(n33(j1),i0,izb) + b3(j1,izb) * yt(n31(j1),izb) * yt(n32(j1),izb)
          EndDo
          !XDIR XLOOP_INNER(1)
          Do j1 = la(4,i0), le(4,i0)
            !XDIR XATOMIC
            dydotdy(n41(j1),i0,izb) = dydotdy(n41(j1),i0,izb) + b4(j1,izb) * yt(n42(j1),izb) * yt(n43(j1),izb) * yt(n44(j1),izb)
            !XDIR XATOMIC
            dydotdy(n42(j1),i0,izb) = dydotdy(n42(j1),i0,izb) + b4(j1,izb) * yt(n43(j1),izb) * yt(n44(j1),izb) * yt(n41(j1),izb)
            !XDIR XATOMIC
            dydotdy(n43(j1),i0,izb) = dydotdy(n43(j1),i0,izb) + b4(j1,izb) * yt(n44(j1),izb) * yt(n41(j1),izb) * yt(n42(j1),izb)
            !XDIR XATOMIC
            dydotdy(n44(j1),i0,izb) = dydotdy(n44(j1),i0,izb) + b4(j1,izb) * yt(n41(j1),izb) * yt(n42(j1),izb) * yt(n43(j1),izb)
          EndDo

          If ( iheat > 0 ) Then
            s1 = 0.0
            !XDIR XLOOP_INNER(1) &
            !XDIR XREDUCTION(+,s1)
            Do j1 = la(1,i0), le(1,i0)
              s1 = s1 + a1(j1) * dcsect1dt9(mu1(j1),izb) * yt(n11(j1),izb)
            EndDo
            s2 = 0.0
            !XDIR XLOOP_INNER(1) &
            !XDIR XREDUCTION(+,s2)
            Do j1 = la(2,i0), le(2,i0)
              s2 = s2 + a2(j1) * dcsect2dt9(mu2(j1),izb) * yt(n21(j1),izb) * yt(n22(j1),izb)
            EndDo
            s3 = 0.0
            !XDIR XLOOP_INNER(1) &
            !XDIR XREDUCTION(+,s3)
            Do j1 = la(3,i0), le(3,i0)
              s3 = s3 + a3(j1) * dcsect3dt9(mu3(j1),izb) * yt(n31(j1),izb) * yt(n32(j1),izb) * yt(n33(j1),izb)
            EndDo
            s4 = 0.0
            !XDIR XLOOP_INNER(1) &
            !XDIR XREDUCTION(+,s4)
            Do j1 = la(4,i0), le(4,i0)
              s4 = s4 + a4(j1) * dcsect4dt9(mu4(j1),izb) * yt(n41(j1),izb) * yt(n42(j1),izb) * yt(n43(j1),izb) * yt(n44(j1),izb)
            EndDo
            dydotdy(ny+1,i0,izb) = s1 + s2 + s3 + s4
          EndIf
        EndIf
      EndDo
    EndDo

    If ( iheat > 0 ) Then
      !XDIR XLOOP_OUTER(2) XASYNC(tid) &
      !XDIR XPRESENT(mask,dydotdy,cv,mex) &
      !XDIR XPRIVATE(sdot)
      Do izb = zb_lo, zb_hi
        Do j1 = 1, msize
          If ( mask(izb) ) Then
            sdot = 0.0
            !XDIR XLOOP_INNER(1) &
            !XDIR XREDUCTION(-,sdot)
            Do i0 = 1, ny
              sdot = sdot - mex(i0)*dydotdy(j1,i0,izb) / cv(izb)
            EndDo
            dydotdy(j1,ny+1,izb) = sdot
          EndIf
        EndDo
      EndDo
    EndIf

    !XDIR XLOOP_OUTER(1) XASYNC(tid) &
    !XDIR XPRESENT(mask,ktot)
    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        ktot(3,izb) = ktot(3,izb) + 1
      EndIf
    EndDo

    ! Apply the externally provided factors
    Call jacobian_scale(diag_in,mult_in,mask_in = mask_in)

    If ( idiag >= 5 ) Then
      !XDIR XUPDATE XWAIT(tid) &
      !XDIR XHOST(dydotdy)
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo
          Write(lun_diag,"(a9,i5)") 'JAC_BUILD',izone
          Do i = 1, ny
            Write(lun_diag,"(3a)") 'dYDOT(',nname(i),')/dY'
            Write(lun_diag,"(7es24.16)") (dydotdy(j,i,izb),j=1,ny)
          EndDo
          If ( iheat > 0 ) Then
            Write(lun_diag,"(3a)") 'dYDOT/dT9'
            Write(lun_diag,"(7es24.16)") (dydotdy(ny+1,i,izb),i=1,ny)
            Write(lun_diag,"(a)") 'dT9DOT/dY'
            Write(lun_diag,"(7es24.16)") (dydotdy(j,ny+1,izb),j=1,ny)
            Write(lun_diag,"(a)") 'dT9DOT/dT9'
            Write(lun_diag,"(es24.16)") dydotdy(ny+1,ny+1,izb)
          EndIf
        EndIf
      EndDo
    EndIf

    !XDIR XEXIT_DATA XASYNC(tid) &
    !XDIR XDELETE(mask)

    stop_timer = xnet_wtime()
    timer_jacob = timer_jacob + stop_timer

    Return
  End Subroutine jacobian_build

  Subroutine jacobian_solve(kstep,yrhs,dy,t9rhs,dt9,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! This routine solves the system of equations composed of the Jacobian and RHS vector.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny
    Use xnet_controls, Only: idiag, iheat, lun_diag, nzbatch, szbatch, zb_lo, zb_hi, lzactive, tid
    Use xnet_linalg, Only: LinearSolveBatched_GPU, LinearSolve_CPU
    Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_solve
    Use xnet_types, Only: dp
    Implicit None

    ! Input variables
    Integer, Intent(in) :: kstep
    Real(dp), Intent(in) :: yrhs(ny,zb_lo:zb_hi)
    Real(dp), Intent(in) :: t9rhs(zb_lo:zb_hi)

    ! Output variables
    Real(dp), Intent(out) :: dy(ny,zb_lo:zb_hi)
    Real(dp), Intent(out) :: dt9(zb_lo:zb_hi)

    ! Optional variables
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Integer :: i, izb, izone, istat
    Logical :: any_pivot
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    start_timer = xnet_wtime()
    timer_solve = timer_solve - start_timer

    !XDIR XENTER_DATA XASYNC(tid) &
    !XDIR XCREATE(dy,dt9) &
    !XDIR XCOPYIN(mask,yrhs,t9rhs)

    !XDIR XLOOP_OUTER(1) XASYNC(tid) &
    !XDIR XPRESENT(mask,rhs,yrhs,t9rhs)
    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        !XDIR XLOOP_INNER(1)
        Do i = 1, ny
          rhs(i,izb) = yrhs(i,izb)
        EndDo
        If ( iheat > 0 ) rhs(ny+1,izb) = t9rhs(izb)
      Else
        !XDIR XLOOP_INNER(1)
        Do i = 1, msize
          rhs(i,izb) = 0.0
        EndDo
      EndIf
    EndDo

    ! Solve the linear system
#if defined(XNET_GPU)
#if USE_NOPIVOT
    any_pivot = any(pivot(zb_lo:zb_hi))
#else
    any_pivot = .true.
#endif
    call LinearSolveBatched_GPU &
      & ( 'N', msize, 1, jac(1,1,zb_lo), djac(zb_lo), msize, indx(1,zb_lo), &
      &   dindx(zb_lo), rhs(1,zb_lo), drhs(zb_lo), msize, info(zb_lo), nzbatch, pivot = any_pivot )
#else
    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        call LinearSolve_CPU &
          & ( 'N', msize, 1, jac(1,1,izb), msize, indx(1,izb), rhs(1,izb), msize, info(izb) )
      EndIf
    EndDo
#endif

    !XDIR XLOOP_OUTER(1) XASYNC(tid) &
    !XDIR XPRESENT(mask,rhs,dy,dt9)
    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        !XDIR XLOOP_INNER(1)
        Do i = 1, ny
          dy(i,izb) = rhs(i,izb)
        EndDo
        If ( iheat > 0 ) dt9(izb) = rhs(ny+1,izb)
      EndIf
    EndDo

    If ( idiag >= 6 ) Then
      !XDIR XUPDATE XWAIT(tid) &
      !XDIR XHOST(dy,dt9)
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo
          Write(lun_diag,"(a,i5)") 'JAC_SOLVE',izone
          Write(lun_diag,"(14es10.3)") (dy(i,izb),i=1,ny)
          If ( iheat > 0 ) Write(lun_diag,"(es10.3)") dt9(izb)
        EndIf
      EndDo
    EndIf

    !XDIR XEXIT_DATA XASYNC(tid) &
    !XDIR XCOPYOUT(dy,dt9) &
    !XDIR XDELETE(mask,yrhs,t9rhs)

    stop_timer = xnet_wtime()
    timer_solve = timer_solve + stop_timer

    Return
  End Subroutine jacobian_solve

  Subroutine jacobian_decomp(kstep,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! This routine performs the LU matrix decomposition for the Jacobian.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: idiag, lun_diag, nzbatch, szbatch, zb_lo, zb_hi, lzactive, tid
    Use xnet_linalg, Only: LUDecompBatched_GPU, LUDecomp_CPU
    Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_solve, timer_decmp
    Implicit None

    ! Input variables
    Integer, Intent(in) :: kstep

    ! Optional variables
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Integer :: i, j, izb, izone, istat
    Logical :: any_pivot
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    start_timer = xnet_wtime()
    timer_solve = timer_solve - start_timer
    timer_decmp = timer_decmp - start_timer

    ! Calculate the LU decomposition
#if defined(XNET_GPU)
#if USE_NOPIVOT
    any_pivot = any(pivot(zb_lo:zb_hi))
#else
    any_pivot = .true.
#endif
    call LUDecompBatched_GPU &
      & ( msize, msize, jac(1,1,zb_lo), djac(zb_lo), msize, indx(1,zb_lo), &
      &   dindx(zb_lo), info(zb_lo), nzbatch, pivot = any_pivot )
#else
    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        call LUDecomp_CPU &
          & ( msize, msize, jac(1,1,izb), msize, indx(1,izb), info(izb) )
      EndIf
    EndDo
#endif

    If ( idiag >= 6 ) Then
      !XDIR XUPDATE XWAIT(tid) &
      !XDIR XHOST(jac)
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo
          Write(lun_diag,"(a3,i5,i4)") 'LUD',izone,info(izb)
          Write(lun_diag,"(14es9.1)") ((jac(i,j,izb),j=1,msize),i=1,msize)
        EndIf
      EndDo
    EndIf

    stop_timer = xnet_wtime()
    timer_solve = timer_solve + stop_timer
    timer_decmp = timer_decmp + stop_timer

    Return
  End Subroutine jacobian_decomp

  Subroutine jacobian_bksub(kstep,yrhs,dy,t9rhs,dt9,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! This routine performs back-substitution for a LU matrix and the RHS vector.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny
    Use xnet_controls, Only: idiag, iheat, lun_diag, nzbatch, szbatch, zb_lo, zb_hi, lzactive, tid
    Use xnet_linalg, Only: LUBksubBatched_GPU, LUBksub_CPU
    Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_solve, timer_bksub
    Use xnet_types, Only: dp
    Implicit None

    ! Input variables
    Integer, Intent(in) :: kstep
    Real(dp), Intent(in) :: yrhs(ny,zb_lo:zb_hi)
    Real(dp), Intent(in) :: t9rhs(zb_lo:zb_hi)

    ! Output variables
    Real(dp), Intent(out) :: dy(ny,zb_lo:zb_hi)
    Real(dp), Intent(out) :: dt9(zb_lo:zb_hi)

    ! Optional variables
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Integer :: i, izb, izone
    Logical :: any_pivot
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    start_timer = xnet_wtime()
    timer_solve = timer_solve - start_timer
    timer_bksub = timer_bksub - start_timer

    !XDIR XENTER_DATA XASYNC(tid) &
    !XDIR XCREATE(dy,dt9) &
    !XDIR XCOPYIN(mask,yrhs,t9rhs)

    !XDIR XLOOP_OUTER(1) XASYNC(tid) &
    !XDIR XPRESENT(mask,rhs,yrhs,t9rhs)
    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        !XDIR XLOOP_INNER(1)
        Do i = 1, ny
          rhs(i,izb) = yrhs(i,izb)
        EndDo
        If ( iheat > 0 ) rhs(ny+1,izb) = t9rhs(izb)
      Else
        !XDIR XLOOP_INNER(1)
        Do i = 1, msize
          rhs(i,izb) = 0.0
        EndDo
      EndIf
    EndDo

    ! Solve the LU-decomposed triangular system via back-substitution
#if defined(XNET_GPU)
    ! TODO: pack djac pointers into djacp array with only non-converged points
#if USE_NOPIVOT
    any_pivot = any(pivot(zb_lo:zb_hi))
#else
    any_pivot = .true.
#endif
    call LUBksubBatched_GPU &
      & ( 'N', msize, 1, jac(1,1,zb_lo), djac(zb_lo), msize, indx(1,zb_lo), &
      &   dindx(zb_lo), rhs(1,zb_lo), drhs(zb_lo), msize, info(zb_lo), nzbatch, pivot = any_pivot )
#else
    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        call LUBksub_CPU &
          & ( 'N', msize, 1, jac(1,1,izb), msize, indx(1,izb), rhs(1,izb), msize, info(izb) )
      EndIf
    EndDo
#endif

    !XDIR XLOOP_OUTER(1) XASYNC(tid) &
    !XDIR XPRESENT(mask,rhs,dy,dt9)
    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        !XDIR XLOOP_INNER(1)
        Do i = 1, ny
          dy(i,izb) = rhs(i,izb)
        EndDo
        If ( iheat > 0 ) dt9(izb) = rhs(ny+1,izb)
      EndIf
    EndDo

    If ( idiag >= 6 ) Then
      !XDIR XUPDATE XWAIT(tid) &
      !XDIR XHOST(dy,dt9)
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo
          Write(lun_diag,"(a,i5)") 'BKSUB', izone
          Write(lun_diag,"(14es10.3)") (dy(i,izb),i=1,ny)
          If ( iheat > 0 ) Write(lun_diag,"(es10.3)") dt9(izb)
        EndIf
      EndDo
    EndIf

    !XDIR XEXIT_DATA XASYNC(tid) &
    !XDIR XCOPYOUT(dy,dt9) &
    !XDIR XDELETE(mask,yrhs,t9rhs)

    stop_timer = xnet_wtime()
    timer_solve = timer_solve + stop_timer
    timer_bksub = timer_bksub + stop_timer

    Return
  End Subroutine jacobian_bksub

End Module xnet_jacobian
