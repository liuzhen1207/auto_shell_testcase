for i in {1..10}
do
	sh -x tmp.sh > test_${i}.out 2>&1
	v_fail=`grep "testcase1 fail" ./test_${i}.out|wc -l`
	if [[ ${v_fail} -gt 0 ]];then
		exit 0
	fi

done
