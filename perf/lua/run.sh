master_rps=0
replica_rps=0

for ((i = 0 ; i < $1; i++ )); do 
	rps=$(tarantool 1mops_write.lua --nodes 2 | grep rps)
	master_local_rps=$(echo $rps | awk '{print $2}')
	replica_local_rps=$(echo $rps | awk '{print $4}')
	master_rps=$(( $master_rps + $master_local_rps ))
	replica_rps=$(( $replica_rps + $replica_local_rps ))
done

master_rps=$(( $master_rps / $1 ))
replica_rps=$(( $replica_rps / $1 ))
echo "master_rps: $master_rps"
echo "replica_rps: $replica_rps"
