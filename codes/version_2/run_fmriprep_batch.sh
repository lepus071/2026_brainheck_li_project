#!/bin/bash

# ==============================================================================
# run_fmriprep_batch.sh
#
# fMRIPrep Docker batch preprocessing script (BIDS compliant for standard paper reproducibility)
# 
# Parameter descriptions:
# - Version: nipreps/fmriprep:20.2.7 (LTS stable version)
# - Space: MNI152NLin6Asym and MNI152NLin2009cAsym
# - Denoising: --use-aroma (automatically performs 6mm smoothing and ICA-AROMA motion noise removal)
# - Surface: Default execution of FreeSurfer recon-all
# ==============================================================================

# -- 1. Path and license settings (please modify according to your actual computer situation) ----------------------

# Root directory of BIDS folder
BIDS_DIR="/home/ser/2026_brainhack_li_project/data"

# Target output folder for fMRIPrep
DERIVS_DIR="${BIDS_DIR}/derivatives"

# Absolute path to FreeSurfer License file (Please verify this path is correct!)
# If you have not applied yet, please apply at https://surfer.nmr.mgh.harvard.edu/registration.html
FS_LICENSE="/home/ser/2026_brainhack_li_project/codes/license.txt"

# Subject list file
SUBJ_LIST="/home/ser/2026_brainhack_li_project/codes/subjectlist.txt"

# fMRIPrep working cache directory (for resume on interruption, very important!)
WORK_DIR="/home/ser/2026_brainhack_li_project/work"

# Persistent TemplateFlow cache on C: (always-available; avoids re-downloading
# templates on every --rm run). Mounted into the container below.
TF_HOST="/home/ser/templateflow"

# Computer resource allocation
NTHREADS=2       # Extreme downscaling: only allow 2 cores to completely prevent ICA-AROMA simultaneous bursts
MEM_MB=12288     # Reduce Docker memory limit to 12GB (leave 4GB for Windows system survival)

# ─────────────────────────────────────────────────────────────────────────────

# Check if files and folders exist
if [ ! -d "${BIDS_DIR}" ]; then
    echo "Cannot find BIDS folder: ${BIDS_DIR}"
    exit 1
fi

if [ ! -f "${FS_LICENSE}" ]; then
    echo "Cannot find FreeSurfer License file: ${FS_LICENSE}"
    echo "Please confirm the file exists, or apply on the official website and place it in the path."
    exit 1
fi

if [ ! -f "${SUBJ_LIST}" ]; then
    echo "Cannot find subject list: ${SUBJ_LIST}"
    exit 1
fi

mkdir -p "${DERIVS_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${TF_HOST}"

# -- 2. Execution loop --------------------------------------------------------------

echo "================================================="
echo "  Start launching fMRIPrep batch processing"
echo "  Output directory: ${DERIVS_DIR}/fmriprep"
echo "================================================="

# Read subjectlist.txt and execute line by line
# Supports writing sub-01 or 01
while read -r line || [[ -n "$line" ]]; do
    # Ignore empty lines
    if [[ -z "$line" ]]; then continue; fi
    
    # Ensure subject ID removes 'sub-' prefix (format required by fMRIPrep)
    SUBJ=${line#sub-}
    
    # Changed to check for .success marker file to prevent false positives caused by leftover HTML from forced interruptions
    if [ -f "${DERIVS_DIR}/fmriprep/.success_sub-${SUBJ}" ]; then
        echo "Subject sub-${SUBJ} already has complete preprocessing success marker, auto-skipping."
        echo "-------------------------------------------------"
        continue
    fi
    
    echo "Processing subject: sub-${SUBJ}"
    
    # Execute Docker
    # Parameter explanation:
    # -v: Mount WSL path into Docker container
    # --use-aroma: Enable ICA-AROMA
    # --output-spaces: Output specified standard brain spaces
    # --stop-on-first-crash: Stop immediately on error for easy debugging
    
    docker run -t --rm \
        -v ${BIDS_DIR}:/data:ro \
        -v ${DERIVS_DIR}:/out \
        -v ${FS_LICENSE}:/opt/freesurfer/license.txt:ro \
        -v ${WORK_DIR}:/work \
        -e TEMPLATEFLOW_HOME=/templateflow \
        -v ${TF_HOST}:/templateflow \
        nipreps/fmriprep:20.2.7 \
        /data /out participant \
        --participant-label ${SUBJ} \
        --output-spaces MNI152NLin6Asym MNI152NLin2009cAsym \
        --use-aroma \
        --nthreads ${NTHREADS} \
        --omp-nthreads ${NTHREADS} \
        --mem_mb ${MEM_MB} \
        --low-mem \
        --skip_bids_validation \
        --stop-on-first-crash \
        -w /work
        
    if [ $? -eq 0 ]; then
        echo "sub-${SUBJ} processing complete!"
        touch "${DERIVS_DIR}/fmriprep/.success_sub-${SUBJ}"

        # ---- Auto-cleanup: free disk space after a subject succeeds ----
        # Remove the work scratch for this completed subject (~30-40 GB each).
        # Runs only after the .success marker, so resume for other/failed
        # subjects is preserved. fMRIPrep runs Docker as root, so the work
        # files are root-owned; delete them from a throwaway container so that
        # no sudo/password is needed.
        SUBJ_WORK="fmriprep_wf/single_subject_${SUBJ}_wf"
        if [ -d "${WORK_DIR}/${SUBJ_WORK}" ]; then
            echo "Cleaning work scratch for sub-${SUBJ} to free disk space..."
            docker run --rm --entrypoint rm \
                -v ${WORK_DIR}:/work \
                nipreps/fmriprep:20.2.7 \
                -rf "/work/${SUBJ_WORK}"
        fi
    else
        echo "sub-${SUBJ} processing failed, please check Docker error messages."
        # You can choose not to exit and continue to the next person, or exit 1 here
    fi
    echo "-------------------------------------------------"
    
    echo "To prevent Windows system crash when WSL2/Docker releases massive memory, pause for 60 seconds to let system buffer..."
    sleep 60

done < "${SUBJ_LIST}"

echo "All subjects' fMRIPrep batch processing have been completely executed!"
