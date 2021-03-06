#!/bin/bash

setup() {
	mkdir -p /kontinuous/{src,status}/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}
}

prepare_kube_config() {
	# replace token for kube config
	sed -i "s/{{token}}/$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)/g" /root/.kube/config
}

clone_source() {
	# clone source code if needed
	if [[ "${REQUIRE_SOURCE_CODE}" == "TRUE" ]]; then
		echo "Retrieving source code..."
		git clone -- https://${GIT_USER}@github.com/${GIT_OWNER}/${GIT_REPO}.git /kontinuous/src/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}
		cd /kontinuous/src/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}
		git checkout ${GIT_COMMIT}
	fi
}

check_job_ready() {
	local job_name=$1

	local active_containers=$(kubectl get jobs ${job_name} --namespace=${NAMESPACE} -o template --template="{{.status.active}}")
	if [[ "${active_containers}" == "1" ]]; then
		return 0
	fi
	return 1
}

check_pod_success() {
	local pod_name=$1
	local container_count=$2

	for (( i=0; i<${container_count}; i++  )); do
		local exit_code=$(kubectl get pods ${pod_name} --namespace=${NAMESPACE} -o template --template="{{(index .status.containerStatuses $i).state.terminated.exitCode}}")
		if [[ "${exit_code}" == "<no value>" ]]; then
			continue
		fi
		if [[ "${exit_code}" == "0" ]]; then
			return 0
		fi
	done
	return 1
}

check_job_fail() {
	local job_name=$1

	local failures=$(kubectl get job ${job_name} --namespace=${NAMESPACE} -o template --template="{{.status.failed}}")
	if [[ "${failures}" != "0" || "${failures}" == "<no value>" ]]; then
		return 0
	fi
	return 1
}

check_container_statuses() {
	local job_name=$1
	local pod_name=$2
	local container_count=$3

	# check job for failure (mark ready then fail)
	local check_fail=$(kubectl get jobs ${job_name} --namespace=${NAMESPACE} -o template --template="{{.status.failed}}")
	if [[ "${check_fail}" != "<no value>" ]]; then
		return 1
	fi
	# check containers for failure
	for (( i=0; i<${container_count}; i++ )); do
		local wait_reason=$(kubectl get pods ${pod_name} --namespace=${NAMESPACE} -o template --template="{{(index .status.containerStatuses ${i}).state.waiting.reason}}")
		if [[ "${wait_reason}" == "RunContainerError" ]]; then
			return 1
		fi
		local exit_reason=$(kubectl get pods ${pod_name} --namespace=${NAMESPACE} -o template --template="{{(index .status.containerStatuses ${i}).state.terminated.reason}}")
		if [[ "${exit_reason}" == "Error" ]]; then
			return 1
		fi
	done
	return 0
}

notify_kontinuous() {
	echo "notifying kontinuous"
	local status=$1

	# get job
	local job_name="${PIPELINE_ID}-${BUILD_ID}-${STAGE_ID}"
	# get associated pod
	local pod_name=$(kubectl get pods --namespace=${NAMESPACE} --selector="pipeline=${PIPELINE_ID},build=${BUILD_ID},stage=${STAGE_ID}" --no-headers | awk '{print $1}')

	local docker_image=""
	if [[ -f /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/docker-image ]]; then
		docker_image=$(cat /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/docker-image)
	fi
	local data="{ \"status\": \"${status}\", \"job_name\": \"${job_name}\", \"pod_name\": \"${pod_name}\", \"timestamp\": \"$(date +%s)\", \"docker-image\": \"${docker-image}\" }"
	curl -X POST -H 'Content-Type: application/json' "${KONTINUOUS_URL}/api/v1/pipelines/${GIT_OWNER}/${GIT_REPO}/builds/${BUILD_ID}/stages/${STAGE_ID}" -d "${data}"
}

wait_for_ready() {
	echo "Preparing job..."
	# get job
	local job_name="${PIPELINE_ID}-${BUILD_ID}-${STAGE_ID}"
	# get associated pod
	local pod_name=$(kubectl get pods --namespace="${NAMESPACE}" --selector="pipeline=${PIPELINE_ID},build=${BUILD_ID},stage=${STAGE_ID}" --no-headers | awk '{print $1}')
	# get containers
	local container_count=$(kubectl get pods "${pod_name}" --namespace="${NAMESPACE}" -o template --template="{{len .spec.containers}}")

	# wait until ready
	until [[ -f /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/ready ]]; do
		check_job_ready "${job_name}"
		if [[ "$?" == "0" ]]; then
			touch /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/ready
			notify_kontinuous "RUNNING"
			return 0
		fi

		check_container_statuses "${job_name}" "${pod_name}" "${container_count}"
		if [[ "$?" == "1" ]]; then
			touch /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/fail
			return 1
		fi
		sleep 5
	done
}

wait_for_success() {
	echo "Waiting for job completion..."

	# get job (again)
	local job_name="${PIPELINE_ID}-${BUILD_ID}-${STAGE_ID}"
	# get associated pod (again)
	local pod_name=$(kubectl get pods --namespace=${NAMESPACE} --selector="pipeline=${PIPELINE_ID},build=${BUILD_ID},stage=${STAGE_ID}" --no-headers | awk '{print $1}')
	# get containers (again)
	local container_count=$(kubectl get pods ${pod_name} --namespace=${NAMESPACE} -o template --template="{{len .spec.containers}}")

	until [[ -f /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/success ]]; do

		# check for failure
		if [[ -f /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/fail ]]; then
			return 1
		fi

		check_pod_success "${pod_name}" "${container_count}"
		if [[ "$?" == "0" ]]; then
			touch /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/success
			return 0
		fi

		check_job_fail "${job_name}"
		if [[ "$?" != "0" ]]; then
			touch /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/fail
			return 1
		fi

		check_container_statuses "${job_name}" "${pod_name}" "${container_count}"
		if [[ "$?" == "1" ]]; then
			touch /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/fail
			return 1
		fi
		sleep 5
	done
}

prepare_mc() {
	echo "Setting up logs and artifact storage..."
	mc config host add internal-storage "${S3_URL}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}"
	mc mb internal-storage/kontinuous || true
	mkdir -pv /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/mc/pipelines/${PIPELINE_ID}/builds/${BUILD_ID}/stages/${STAGE_ID}/logs
	mkdir -pv /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/mc/pipelines/${PIPELINE_ID}/builds/${BUILD_ID}/artifacts
}

store_logs() {
	echo "storing logs..."
	# get associated pod
	local pod_name=$(kubectl get pods --namespace=${NAMESPACE} --selector="pipeline=${PIPELINE_ID},build=${BUILD_ID},stage=${STAGE_ID}" --no-headers | awk '{print $1}')
	# get containers
	local container_count=$(kubectl get pods ${pod_name} --namespace=${NAMESPACE} -o template --template="{{len .spec.containers}}")
	# iterate through pods
	for (( i=0; i<${container_count}; i++ )); do
		local container_name=$(kubectl get pods ${pod_name} --namespace=${NAMESPACE} -o template --template="{{(index .spec.containers ${i}).name}}")
		kubectl logs ${pod_name} ${container_name} --namespace=${NAMESPACE} > /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/mc/pipelines/${PIPELINE_ID}/builds/${BUILD_ID}/stages/${STAGE_ID}/logs/result-${i}.log
	done
	mc mirror --quiet --force /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/mc/ internal-storage/kontinuous
}

store_artifacts() {
	echo "storing artifacts..."
	# get associated pod
	local pod_name=$(kubectl get pods --namespace=${NAMESPACE} --selector="pipeline=${PIPELINE_ID},build=${BUILD_ID},stage=${STAGE_ID}" --no-headers | awk '{print $1}')
	local artifacts=$(kubectl get pods ${pod_name} --namespace=${NAMESPACE} -o template --template="{{.metadata.annotations.kontinuous_artifacts}}")
	if [[ "$artifacts" != "<no value>" ]]; then
		local container_count=$(kubectl get pods ${pod_name} --namespace=${NAMESPACE} -o template --template="{{len .spec.containers}}")
		for (( i=0; i<${container_count}; i++ )); do
			local container_name=$(kubectl get pods ${pod_name} --namespace=${NAMESPACE} -o template --template="{{(index .spec.containers ${i}).name}}")
			if [[ "$container_name" =~ ^(command|docker)-agent$ ]]; then
				kubectl exec ${pod_name} --namespace=${NAMESPACE} -c ${container-name} -- cp $artifacts /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/mc/pipelines/${PIPELINE_ID}/builds/${BUILD_ID}/artifacts/
			fi
		done
	fi
	mc mirror --quiet --force /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/mc/ internal-storage/kontinuous
}

pass() {
	prepare_mc
	store_logs
	store_artifacts
	notify_kontinuous "SUCCESS"
	touch /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/complete
	kubectl delete jobs --namespace=${NAMESPACE} ${PIPELINE_ID}-${BUILD_ID}-${STAGE_ID}
	echo 'Build Successful'
	exit 0
}

fail() {
	prepare_mc
	store_logs
	notify_kontinuous "FAIL"
	touch /kontinuous/status/${PIPELINE_ID}/${BUILD_ID}/${STAGE_ID}/fail
	kubectl delete jobs --namespace=${NAMESPACE} ${PIPELINE_ID}-${BUILD_ID}-${STAGE_ID}
	echo 'Build Fail'
	exit 1
}

main() {
	setup
	prepare_kube_config; if [[ "$?" != "0" ]]; then fail; fi
	clone_source;        if [[ "$?" != "0" ]]; then fail; fi
	wait_for_ready;      if [[ "$?" != "0" ]]; then fail; fi
	wait_for_success;    if [[ "$?" != "0" ]]; then fail; fi
	pass
}

main $@
