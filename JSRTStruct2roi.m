function [roi, dcmrt, dcm] = rtstruct2imagejroi(rtstructfile, dicomdir, outdir, savetype)
    % RTSTRUCT2IMAGEJROI Extract RT Structure coordinates from DICOM RTSTRUCT file
    % and convert to ImageJ or ASCII ROI format.
    %
    % Input:
    %   rtstructfile: DICOM RTSTRUCT file path
    %   dicomdir: Directory containing DICOM CT/MRI images
    %   outdir: Directory to save the contours
    %   savetype: 'imagej', 'ascii' or 'both'
    %
    % Output:
    %   roi: Structure with x, y coordinates of each RT StructureSetROISequence
    %   dcmrt: Header structure from RTSTRUCT
    %   dcm: DICOM image data and metadata

    %% Prompt for input if not provided
    if nargin == 0
        [fname, dname] = uigetfile('*.dcm', 'Select DICOM RTSTRUCT file');
        if ~fname, return; end
        rtstructfile = fullfile(dname, fname);

        dicomdir = uigetdir('.', 'Select DICOM Images directory');
        if dicomdir == 0, return; end

        outdir = uigetdir('.', 'Select Output directory');
        if outdir == 0, return; end

        savetype = 'imagej';
    end

    %% Read DICOM Image Sequence
    fprintf('>> Reading DICOM Sequence...\n');
    [dcm, UseInstanceNumber] = ReadDICOMSequence(dicomdir, 1);
    if isempty(dcm), error('No valid DICOM images found.'); end
    refFrameUID = dcm.info(1).FrameOfReferenceUID;
    fprintf('Done!\n');

    %% Read RTSTRUCT file with enhanced error handling
    fprintf('>> Reading RTSTRUCT file...\n');
    try
        dcmrt = dicominfo(rtstructfile, 'UseVRHeuristic', false, 'UseDictionaryVR', true);
    catch ME
        error('Failed to read RTSTRUCT file. Error: %s', ME.message);
    end

    if ~strcmpi(dcmrt.Modality, 'RTSTRUCT')
        error('The DICOM file does not contain an RTSTRUCT modality.');
    end
    fprintf('Done!\n');

    %% Debug: Print the contents of StructureSetROISequence
    if isfield(dcmrt, 'StructureSetROISequence')
        disp('StructureSetROISequence:');
        disp(dcmrt.StructureSetROISequence);
    else
        error('No StructureSetROISequence found in the RTSTRUCT file.');
    end

    %% Get ROIContourSequence
    if isfield(dcmrt, 'ROIContourSequence')
        disp('ROIContourSequence found.');
        roicontseq = dcmrt.ROIContourSequence;
        roicontseq_fields = fieldnames(roicontseq);
    else
        error('No ROIContourSequence found in the RTSTRUCT file.');
    end

    %% Process each ROI
    sset = dcmrt.StructureSetROISequence;
    sset_fields = fieldnames(sset);

    for k = 1:numel(sset_fields)
        roi(k).name = sset.(sset_fields{k}).ROIName;
        roi(k).id = sset.(sset_fields{k}).ROINumber;

        % Check frame of reference match
        if ~strcmp(refFrameUID, sset.(sset_fields{k}).ReferencedFrameOfReferenceUID)
            error('The RTStruct and the DICOM Image Set do not match.');
        end

        % Loop through ROIContourSequence to find matching contours
        for itemField = 1:numel(roicontseq_fields)
            contourItem = roicontseq.(roicontseq_fields{itemField});
            if contourItem.ReferencedROINumber == roi(k).id
                if isfield(contourItem, 'ContourSequence')
                    contourstruct = contourItem.ContourSequence;

                    % Extract slice information and match to DICOM slices
                    roi(k).sliceNumbers = extractSliceNumbers(contourItem, dcm);

                    % Call extractContours to process contours and save them
                    extractContours(dcm, roi(k), contourstruct, savetype, outdir);
                else
                    fprintf('No contours found for ROI: %s\n', roi(k).name);
                end
            end
        end
    end

    fprintf('Contours converted successfully!\n');
end

%% Helper function to extract contours and save them
function extractContours(dcm, roi, contourstruct, savetype, outdir)
    % Extract contour data and convert it to ImageJ ROI or ASCII format

    % Set output folder for contours
    outfolder = fullfile(outdir, 'contours');
    if ~exist(outfolder, 'dir'), mkdir(outfolder); end
    if strcmpi(savetype, 'ascii') || strcmpi(savetype, 'both')
        mkdir(outfolder, roi.name);
    end

    % Create a temporary folder for ImageJ ROIs inside the output directory
    tmpRoiFolder = fullfile(outdir, 'tmp_roi');
    if strcmpi(savetype, 'imagej') || strcmpi(savetype, 'both')
        if ~exist(tmpRoiFolder, 'dir')
            mkdir(tmpRoiFolder);
        end
    end

    % Process contours for the given ROI
    for l = 1:numel(fieldnames(contourstruct))
        contour_data = contourstruct.(sprintf('Item_%d', l)).ContourData;
        try
            if ischar(contour_data)
                contour_data = str2double(strsplit(contour_data));
            end
        catch
            error('Error reading ContourData for ROI: %s', roi.name);
        end

        npoints = numel(contour_data) / 3;
        rdata = reshape(contour_data, [3, npoints])';
        roi.data{l} = rdata(:, 1:2);

        % Convert contour to pixel coordinates
        px = (roi.data{l}(:, 1) - dcm.info(1).ImagePositionPatient(1)) / dcm.info(1).PixelSpacing(1);
        py = (roi.data{l}(:, 2) - dcm.info(1).ImagePositionPatient(2)) / dcm.info(1).PixelSpacing(2);

        % Get the corresponding slice number from ROI
        sliceNum = roi.sliceNumbers(l);

        % Save to ASCII if required
        if strcmpi(savetype, 'ascii') || strcmpi(savetype, 'both')
            dlmwrite(fullfile(outfolder, roi.name, sprintf('roi_%d_%d.txt', roi.id, l)), [px, py]);
        end

        % Save as ImageJ ROI
        if strcmpi(savetype, 'imagej') || strcmpi(savetype, 'both')
            roislice = CreateImageJROISlice(px, py, sliceNum);
            roifilename = sprintf('%s_%04d.roi', roi.name, sliceNum);
            roienc = ij.io.RoiEncoder(fullfile(tmpRoiFolder, roifilename));
            roienc.write(roislice);
        end
    end

    % Zip the ROI files if saving in ImageJ format
    if strcmpi(savetype, 'imagej') || strcmpi(savetype, 'both')
        roifilename = sprintf('%s.zip', roi.name);
        zip(fullfile(outfolder, roifilename), {'*.roi'}, tmpRoiFolder);
        rmdir(tmpRoiFolder, 's');
    end
end

%% Helper function to extract slice numbers from ROIContourSequence
function sliceNumbers = extractSliceNumbers(contourItem, dcm)
    nContours = numel(fieldnames(contourItem.ContourSequence));
    sliceNumbers = zeros(1, nContours);

    for i = 1:nContours
        contourImage = contourItem.ContourSequence.(sprintf('Item_%d', i)).ContourImageSequence;
        sopInstanceUID = contourImage.Item_1.ReferencedSOPInstanceUID;

        % Match the SOPInstanceUID with the DICOM slices
        instanceUIDs = {dcm.info.SOPInstanceUID}';
        sliceIndex = find(strcmp(sopInstanceUID, instanceUIDs));

        % If a match is found, use the corresponding slice number
        if ~isempty(sliceIndex)
            sliceNumbers(i) = sliceIndex;
        else
            fprintf('Could not find matching slice for SOPInstanceUID: %s\n', sopInstanceUID);
        end
    end
end

%% Helper function to read DICOM images and metadata
function [dcm, UseInstanceNumber] = ReadDICOMSequence(folder, int2hu)
    % Read DICOM sequence from a folder and return images and metadata

    dcm = [];
    UseInstanceNumber = true;

    dcmfiles = dir(fullfile(folder, '*.dcm'));
    if isempty(dcmfiles), error('No DICOM files found in the directory.'); end

    for k = 1:length(dcmfiles)
        img = double(dicomread(fullfile(dcmfiles(k).folder, dcmfiles(k).name)));
        info = dicominfo(fullfile(dcmfiles(k).folder, dcmfiles(k).name));

        if strcmpi(info.Modality, 'rtstruct')
            continue;
        end

        if int2hu == 1
            img = img * double(info.RescaleSlope) + double(info.RescaleIntercept);
            img(img < double(info.RescaleIntercept)) = double(info.RescaleIntercept);
        else
            img(img <= 0) = 1;
        end

        dcm.img(:, :, k) = img;
        dcm.info(k) = info;
    end

    % Sort by InstanceNumber or ImagePositionPatient
    try
        indx = [dcm.info.InstanceNumber]';
        [~, sorted_idx] = sort(indx);
    catch
        pos = [dcm.info.ImagePositionPatient]';
        [~, sorted_idx] = sort(pos(:, 3), 'descend');
        UseInstanceNumber = false;
    end

    dcm.img = dcm.img(:, :, sorted_idx);
    dcm.info = dcm.info(sorted_idx);

    % Ensure all data is cast to double for operations
    width = double(dcm.info(1).Width);
    height = double(dcm.info(1).Height);
    pixelSpacing = double(dcm.info(1).PixelSpacing);
    imagePosition = double(dcm.info(1).ImagePositionPatient);

    % Generate pixel coordinate grids (x, y, z) using linspace
    dcm.x = linspace(imagePosition(1), imagePosition(1) + (width - 1) * pixelSpacing(1), width);
    dcm.y = linspace(imagePosition(2), imagePosition(2) + (height - 1) * pixelSpacing(2), height);
    dcm.z = [dcm.info.ImagePositionPatient]';
    dcm.z = dcm.z(:, 3);
end
%% Helper function to create ImageJ ROIs
function roislice = CreateImageJROISlice(px, py, sliceNum)
    % Import ImageJ classes
    import ij.process.FloatPolygon;
    import ij.gui.PolygonRoi;

    % Create the FloatPolygon
    xy = FloatPolygon(px, py);

    % Create a Polygon ROI
    roislice = PolygonRoi(xy, PolygonRoi.POLYGON);
    roislice.setPosition(sliceNum);
end
