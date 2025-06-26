set -e
set -x
#VARIABLES
BLOCKSIZE=$1
FILEHANDLECOUNT=1
IOTYPE="read"
NUMFILES=1

#CONSTANTS
ITERATIONS=5
IODEPTH=1
READ_AHEAD_KB=1024
FILESIZE="1gb"
BUCKET="<BUCKET-TO-TEST-AGAINST>"
ARTIFACTS_BUCKET="<BUCKET-FOR-ARTIFACTS>"


TESTCASE="numfile-${NUMFILES}-io-${IOTYPE}-fs-${FILESIZE}-bs-${BLOCKSIZE}-fh-${FILEHANDLECOUNT}"

gsutil cp ./jobfile.fio. gs://${ARTIFACTS_BUCKET}/${TESTCASE}/
gsutil cp ./parser-script.py gs://${ARTIFACTS_BUCKET}/${TESTCASE}/
gsutil cp ./mount-config.yml gs://${ARTIFACTS_BUCKET}/${TESTCASE}/

gcloud compute instances create rapid-perf-$TESTCASE \
    --project=gcs-fuse-test \
    --zone=us-west4-a \
    --machine-type=c4-standard-192 \
    --network-interface=network-tier=PREMIUM,nic-type=GVNIC,stack-type=IPV4_ONLY,subnet=default \
    --maintenance-policy=MIGRATE \
    --provisioning-model=STANDARD \
    --service-account=927584127901-compute@developer.gserviceaccount.com \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --create-disk=auto-delete=yes,boot=yes,device-name=rapid-perf,disk-resource-policy=projects/gcs-fuse-test/regions/us-west4/resourcePolicies/default-schedule-1,image=projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-amd64-v20250624,mode=rw,provisioned-iops=9000,provisioned-throughput=1640,size=1000,type=hyperdisk-balanced \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels=goog-ops-agent-policy=v2-x86-template-1-4-0,goog-ec-src=vm_add-gcloud \
    --reservation-affinity=any \
    --network-performance-configs=total-egress-bandwidth-tier=TIER_1 \
    --metadata=enable-osconfig=TRUE,enable-oslogin=true,BUCKET=${BUCKET},NUMFILES=${NUMFILES},ITERATIONS=${ITERATIONS},IODEPTH=${IODEPTH},READ_AHEAD_KB=${READ_AHEAD_KB},BLOCKSIZE=${BLOCKSIZE},FILESIZE=${FILESIZE},FILEHANDLECOUNT=${FILEHANDLECOUNT},IOTYPE=${IOTYPE} \
    --metadata-from-file=startup-script=starter-script.sh \
#
