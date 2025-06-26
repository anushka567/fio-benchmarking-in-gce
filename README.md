# fio-benchmarking-in-gce

Substitute the perf test bucket name and artifacts bucket name in `create-vm-and-start-test.sh` at line 14 and 15.

To run for different block size, run  `bash run-combo.sh`

Otherwise `bash create-vm-and-start-test.sh  "<blocksize>" `


Other configs like filesize , iotype can be modified directly in the `create-vm-and-start-test.sh` script. 
