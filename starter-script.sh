set -x
# Exit immediately if a command exits with a non-zero status.
set -e

# Extract the metadata parameters passed, for which we need the zone of the GCE VM
# on which the tests are supposed to run.
ZONE=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone)
echo "Got ZONE=\"${ZONE}\" from metadata server."
# The format for the above extracted zone is projects/{project-id}/zones/{zone}, thus, from this
# need extracted zone name.
ZONE_NAME=$(basename $ZONE)
# This parameter is passed as the GCE VM metadata at the time of creation.(Logic is handled in louhi stage script)

# ITERATIONS
ITERATIONS=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.ITERATIONS)')
echo "ITERATIONS : \"${ITERATIONS}\""
# IODEPTH
IODEPTH=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.IODEPTH)')
echo "IODEPTH : \"${IODEPTH}\""
# READ_AHEAD_KB
READ_AHEAD_KB=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.READ_AHEAD_KB)')
echo "READ_AHEAD_KB : \"${READ_AHEAD_KB}\""
# FILESIZE
FILESIZE=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.FILESIZE)')
echo "FILESIZE : \"${FILESIZE}\""
# BLOCKSIZE
BLOCKSIZE=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.BLOCKSIZE)')
echo "BLOCKSIZE : \"${BLOCKSIZE}\""
# FILEHANDLECOUNT
FILEHANDLECOUNT=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.FILEHANDLECOUNT)')
echo "FILEHANDLECOUNT : \"${FILEHANDLECOUNT}\""
# IOTYPE
IOTYPE=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.IOTYPE)')
echo "IOTYPE : \"${IOTYPE}\""
# NUMFILES
NUMFILES=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.NUMFILES)')
echo "NUMFILES : \"${NUMFILES}\""
# BUCKET
BUCKET=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.BUCKET)')
echo "BUCKET : \"${BUCKET}\""

# Disable automatic updates
sudo systemctl stop apt-daily.timer
sudo systemctl stop apt-daily-upgrade.timer
sudo systemctl mask apt-daily.timer
sudo systemctl mask apt-daily-upgrade.timer

# run the following commands to add starterscriptuser
sudo adduser --ingroup google-sudoers --disabled-password --home=/home/starterscriptuser --gecos "" starterscriptuser
# Run the following as starterscriptuser
sudo -u starterscriptuser bash -c '
  set -e
  set -x
  export ITERATIONS='$ITERATIONS'
  export IODEPTH='$IODEPTH'
  export READ_AHEAD_KB='$READ_AHEAD_KB'
  export FILESIZE='$FILESIZE'
  export BLOCKSIZE='$BLOCKSIZE'
  export FILEHANDLECOUNT='$FILEHANDLECOUNT'
  export IOTYPE='$IOTYPE'
  export NUMFILES='$NUMFILES'
  export BUCKET='$BUCKET'
  export ARTIFACTS_BUCKET='anushkadhn-test'

  retry_apt_command() {
    local max_retries=10
    local delay=10
    local cmd=("$@")
    local attempts=0

    while [[ $attempts -lt $max_retries ]]; do
      if "${cmd[@]}" -y; then
        return 0
      else
        echo "Command ${cmd[@]} failed. Retrying in ${delay} seconds..."
        sleep "$delay"
        attempts=$((attempts + 1))
      fi
    done
    echo "Command ${cmd[@]} failed after $max_retries retries. Aborting."
    return 1
  }

  echo "Installing dependencies..."
  retry_apt_command sudo apt-get install libaio-dev
  retry_apt_command sudo apt-get install gcc make git


  TESTCASE="numfile-${NUMFILES}-io-${IOTYPE}-fs-${FILESIZE}-bs-${BLOCKSIZE}-fh-${FILEHANDLECOUNT}"
  cd ~
  HOMEDIR=$(pwd)

  git clone -b fio-3.39 https://github.com/axboe/fio.git
  cd fio
  ./configure && sudo make && sudo make install
  cd ..

  wget -O go_tar.tar.gz https://go.dev/dl/go1.24.4.linux-amd64.tar.gz -q
  sudo rm -rf /usr/local/go && tar -xzf go_tar.tar.gz && sudo mv go /usr/local
  export PATH=$PATH:/usr/local/go/bin

  git clone https://github.com/GoogleCloudPlatform/gcsfuse.git
  cd gcsfuse
  git checkout v3.0.0
  go build .
  cd ..


  touch details.txt
  echo "go version : $(go version)" >> details.txt
  echo "fio version : $(fio --version)" >> details.txt
  echo "GCSFuse version: 3.0.0" >> details.txt
  gsutil cp details.txt gs://${ARTIFACTS_BUCKET}/${TESTCASE}/

  gsutil cp gs://${ARTIFACTS_BUCKET}/${TESTCASE}/jobfile.fio ${HOMEDIR}/
  gsutil cp gs://${ARTIFACTS_BUCKET}/${TESTCASE}/parser-script.py ${HOMEDIR}/
  gsutil cp gs://${ARTIFACTS_BUCKET}/${TESTCASE}/mount-config.yml ${HOMEDIR}/

  mkdir ${HOMEDIR}/mnt

  ${HOMEDIR}/gcsfuse/gcsfuse --config-file=${HOMEDIR}/mount-config.yml $BUCKET ${HOMEDIR}/mnt

  export MNT="${HOMEDIR}"/mnt
  # Get device ID from mount path (as root)
  DEVICE_ID=$(stat -c "%d" ${HOMEDIR}/mnt)
  # Then use the device ID to write to the read_ahead_kb as root
  echo "${READ_AHEAD_KB}" | sudo tee /sys/class/bdi/0:${DEVICE_ID}/read_ahead_kb


  for ((i=1; i<=$ITERATIONS; i++)); do
    output_file="${HOMEDIR}/fio_output_iteration_${i}.json"
    MNTDIR=${HOMEDIR}/mnt IODEPTH=$IODEPTH TESTCASE=$TESTCASE IOTYPE=$IOTYPE BLOCKSIZE=$BLOCKSIZE FILESIZE=$FILESIZE NUMFILES=$NUMFILES FILEHANDLECOUNT=$FILEHANDLECOUNT fio --output-format=json ${HOMEDIR}/jobfile.fio  > "$output_file" 2>&1

    # Check if FIO command was successful
    if [[ $? -eq 0 ]]; then
      echo "FIO iteration $i completed successfully. Output saved to: $output_file"
      gsutil cp $output_file gs://${ARTIFACTS_BUCKET}/${TESTCASE}/raw-fio-output/
    else
      echo "FIO iteration $i failed. Output saved to: $output_file"
      # You can add more error handling here, e.g., exit the script.
    fi
  done


  umount ${HOMEDIR}/mnt

  # Parsing logic
  python3 parser-script.py --iterations=$ITERATIONS --output-filepath="${HOMEDIR}/fio_output_iteration_"
  gsutil cp fio_results.csv gs://$ARTIFACTS_BUCKET/${TESTCASE}/results/

'





