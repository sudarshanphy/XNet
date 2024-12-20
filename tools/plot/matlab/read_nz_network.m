function [nname,aa,zz,nn,sp,be] = read_nz_network(data_directory)
%--------------------------------------------------------------------------
% [axis_id] = draw_nz_network(data_directory,pcolor,psize)
% Scatter plot of the isotopes in a specified netwinv file.
% Inputs>  data_directory: directory hosting netwinv file to be plotted.
%          pcolor: point color
%          psize: point size
% Outputs: axis_id: handle of current axis
%--------------------------------------------------------------------------
% Open file
  filename=strcat(data_directory,'/netwinv');
  fileID=fopen(filename);
  
% Read network size
  dataread=textscan(fileID,'%d',1);
  ny=cell2mat(dataread);

% Skip thermodata
  dataread=textscan(fileID,'%d',1);
  
% Read nuclear names
  dataread = textscan(fileID,'%s',ny);
  nname=dataread{1};

% Read nuclear data, skipping partition function
  aa = zeros(ny,1);
  zz = zeros(ny,1);
  nn = zeros(ny,1);
  sp = zeros(ny,1);
  be = zeros(ny,1);
  file_form='%*s %f %f %f %f %f';
  for i=1:ny        
    dataread=textscan(fileID,file_form,1);
    [aa(i),zz(i),nn(i),sp(i),be(i)]=dataread{1:5};
    
    dataread=textscan(fileID,'%f %f %f %f %f %f %f %f',3);

  end

end