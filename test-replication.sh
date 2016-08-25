#!/bin/bash
set -o errexit
set -o nounset

IMG="$1"

R1_CONTAINER="mongodb-r1"
R1_DATA_CONTAINER="${R1_CONTAINER}-data"
R1_PORT=27117

R2_CONTAINER="mongodb-r2"
R2_DATA_CONTAINER="${R2_CONTAINER}-data"
R2_PORT=27217

R3_CONTAINER="mongodb-r3"
R3_DATA_CONTAINER="${R3_CONTAINER}-data"
R3_PORT=27217

function cleanup {
  echo "Cleaning up"
  docker rm -f "$R1_CONTAINER" "$R1_DATA_CONTAINER" "$R2_CONTAINER" "$R2_DATA_CONTAINER" "$R3_CONTAINER" "$R3_DATA_CONTAINER" || true
}

trap cleanup EXIT
cleanup

# Helper script
READ_SUGGESTED_CONFIG_SCRIPT='
import sys, json, pipes
c = json.load(sys.stdin)["suggested_configuration"]
opts = []
for k, v in c.items():
  opts.append("-e")
  opts.append(pipes.quote("{0}={1}".format(k, v)))
print "ENV_ARGS+=({0})".format(" ".join(opts))
'

READ_DATABASE_URL_SCRIPT='
import sys, json
print json.load(sys.stdin)["url"] + "&x-sslVerify=false",
'

USER=testuser
PASSPHRASE=testpass
DATABASE=db  # TODO: test with custom DB


# ENV_ARGS will represent the configuration that Sweetness would be passing.
# It's the suggested_configuration obtained from --discover, to which we add
# USERNAME, DATABASE, EXPOSE_HOST and EXPOSE_PORT_XXXXX.

ENV_ARGS=()
ENV_ARGS=("-e" "USERNAME=$USER" "-e" "PASSPHRASE=$PASSPHRASE" "-e" "DATABASE=$DATABASE")

# If ENABLE_DEBUG is set in our environment, we'll pass it through to the container environment,
# enable xtrace here, and disable cleanup.
if [[ -n "${ENABLE_DEBUG:-""}" ]]; then
  set -o xtrace
  ENV_ARGS+=("-e" "ENABLE_DEBUG=1")
  trap "echo 'ENABLE_DEBUG is set, skipping cleanup'" EXIT
fi


echo "Importing suggested configuration"
eval "$(docker run -i "$IMG" --discover | python -c "$READ_SUGGESTED_CONFIG_SCRIPT")"


R1_ENV_ARGS+=(
  "${ENV_ARGS[@]}"
  "-e" "PORT=${R1_PORT}"
  "-e" "EXPOSE_HOST=$R1_CONTAINER" "-e" "EXPOSE_PORT_${R1_PORT}=${R1_PORT}"
)

R2_ENV_ARGS+=(
  "${ENV_ARGS[@]}"
  "-e" "PORT=${R2_PORT}"
  "-e" "EXPOSE_HOST=$R2_CONTAINER" "-e" "EXPOSE_PORT_${R2_PORT}=${R2_PORT}"
)

R3_ENV_ARGS+=(
  "${ENV_ARGS[@]}"
  "-e" "PORT=${R3_PORT}"
  "-e" "EXPOSE_HOST=$R3_CONTAINER" "-e" "EXPOSE_PORT_${R3_PORT}=${R3_PORT}"
)

echo "Initializing data containers"

for data_container in  "$R1_DATA_CONTAINER" "$R2_DATA_CONTAINER" "$R3_DATA_CONTAINER"; do
  docker create --name "$data_container" "$IMG"
done

# Now: a hackish hack. We need to get the IP address of our containers so we can add them to
# --add-host, but there's a chicken and egg problem:
# + We can only set --add-host at startup.
# + We can only get a container's IP address after it started.
# + We have > 1 containers that need to know each other's IP address.
# So, since we know recent versions of Docker reuse IP addresses, we'll launch as many containers
# as we need, and get their IP addresses. We expect the same IP addresses will be reused. Ugh.

echo "Guessing IPs"

for container in "$R1_CONTAINER" "$R2_CONTAINER" "$R3_CONTAINER"; do
  docker run -d --name "$container" "quay.io/aptible/debian:wheezy" sh -c 'hostname -I && exec sleep 10000'
done

# xargs trims whitespace for us here
R1_IP="$(docker logs "$R1_CONTAINER" | xargs)"
R2_IP="$(docker logs "$R2_CONTAINER" | xargs)"
R3_IP="$(docker logs "$R3_CONTAINER" | xargs)"
docker kill "$R1_CONTAINER" "$R2_CONTAINER" "$R3_CONTAINER"
docker rm   "$R1_CONTAINER" "$R2_CONTAINER" "$R3_CONTAINER"

# This is here to emulate functional DNS.
IP_ARGS=(
  "--add-host" "${R1_CONTAINER}:${R1_IP}"
  "--add-host" "${R2_CONTAINER}:${R2_IP}"
  "--add-host" "${R3_CONTAINER}:${R3_IP}"
)

function check_ip () {
  local container="$1"
  local expected_ip="$2"
  local real_ip
  real_ip="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$container")"

  if [[ "$expected_ip" != "$real_ip" ]]; then
    echo "${container} IP is unexpected: expected ${expected_ip}, got ${real_ip}"
    exit 1
  fi
}

function validate_cluster_conf () {
  local mongo_url="$1"
  for attempt in $(seq 1 5); do
    echo "Validating voting and priority configuration (from ${mongo_url}, attempt ${attempt})"
    if [[ "$attempt" -ge 5 ]]; then
      echo "Some members had an invalid configuration after 5 attempts"
      exit 1
    fi
    if docker run --rm -i "${IP_ARGS[@]}" "$IMG" --client "$mongo_url" "/tmp/test/assert-votes.js"; then
      break
    fi
    sleep 2
  done
}


echo "Initializing first member"


docker run -i --rm \
  "${R1_ENV_ARGS[@]}" \
  "${IP_ARGS[@]}" \
  --volumes-from "$R1_DATA_CONTAINER" \
  "$IMG" --initialize

docker run -d --name="$R1_CONTAINER" \
  "${R1_ENV_ARGS[@]}" \
  "${IP_ARGS[@]}" \
  --volumes-from "$R1_DATA_CONTAINER" \
  "$IMG"

check_ip "$R1_CONTAINER" "$R1_IP"


# Wait until the first node becomes the master
R1_URL="$(docker run -i "${R1_ENV_ARGS[@]}" "$IMG" --connection-url | python -c "$READ_DATABASE_URL_SCRIPT")"
until docker run --rm -i "${IP_ARGS[@]}" "$IMG" --client "$R1_URL" --quiet --eval 'quit(db.isMaster()["ismaster"] ? 0 : 1)'; do sleep 2; done


echo "Initializing second member"
R2_URL="$(docker run -i "${R2_ENV_ARGS[@]}" "$IMG" --connection-url | python -c "$READ_DATABASE_URL_SCRIPT")"
R2_ADMIN_URL="$(docker run -i "${R2_ENV_ARGS[@]}" -e "DATABASE=admin" "$IMG" --connection-url | python -c "$READ_DATABASE_URL_SCRIPT")"

docker run -i --rm \
  "${R2_ENV_ARGS[@]}" \
  "${IP_ARGS[@]}" \
  --volumes-from "$R2_DATA_CONTAINER" \
  "$IMG" --initialize-from "$R1_URL"

# Now, simulate some time before restarting R2. We want to make sure the primary does not 
# step down during this time.

echo "Simulating ${R2_CONTAINER} start delay"
delay=20
step=4
for time_left in $(seq "$delay" "-${step}" 1); do
  echo "${time_left} seconds left..."
  sleep "$step"
done

# Check that R1 didn't step down

if docker logs "$R1_CONTAINER" | grep "relinquishing primary"; then
  echo "FAIL: ${R1_CONTAINER} stepped down:"
  docker logs "$R1_CONTAINER"
  exit 1
fi

# But also check that R1 noticed R2 was down. The log message differs in Mongo
# 2.6, 3.2, so we test for both (2.6 first, then 3.2)
if ! docker logs "$R1_CONTAINER" | grep "${R2_CONTAINER}:${R2_PORT} is now in state DOWN"; then
  if ! docker logs "$R1_CONTAINER" | grep "${R2_CONTAINER}:${R2_PORT}; ExceededTimeLimit"; then
    # This isn't technically a test *failure*. However, we were unable to *demonstrate* that the
    # system reacted properly to R2 going down for a restart, so we have to abort.
    docker logs "$R1_CONTAINER"
    echo "${R1_CONTAINER} did not realize that ${R2_CONTAINER} went down - aborting test"
    exit 1
  fi
fi

docker run -d --name "$R2_CONTAINER" \
  "${R2_ENV_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  "${IP_ARGS[@]}" \
  --volumes-from "$R2_DATA_CONTAINER" \
  "$IMG"

check_ip "$R2_CONTAINER" "$R2_IP"

until docker run --rm -i "${IP_ARGS[@]}" "$IMG" --client "$R2_ADMIN_URL" --quiet --eval 'quit(db.isMaster()["secondary"] ? 0 : 1)'; do sleep 2; done

validate_cluster_conf "$R2_ADMIN_URL"


echo "Initializing third member from second"
# This will only pass if the initialization script is smart enough to resolve the real primary and not rely on --initialize-from
docker run -i --rm \
  "${R3_ENV_ARGS[@]}" \
  "${IP_ARGS[@]}" \
  --volumes-from "$R3_DATA_CONTAINER" \
  "$IMG" --initialize-from "$R2_URL"

docker run -d --name="$R3_CONTAINER" \
  "${R3_ENV_ARGS[@]}" \
  "${IP_ARGS[@]}" \
  --volumes-from "$R3_DATA_CONTAINER" \
  "$IMG"

check_ip "$R3_CONTAINER" "$R3_IP"

R3_ADMIN_URL="$(docker run -i "${R3_ENV_ARGS[@]}" -e "DATABASE=admin" "$IMG" --connection-url | python -c "$READ_DATABASE_URL_SCRIPT")"
until docker run --rm -i "${IP_ARGS[@]}" "$IMG" --client "$R3_ADMIN_URL" --quiet --eval 'quit(db.isMaster()["secondary"] ? 0 : 1)'; do sleep 2; done

# And now, check that our cluster looks healthy!
validate_cluster_conf "$R3_ADMIN_URL"

echo "Cluster configuration:"
docker run --rm -i "${IP_ARGS[@]}" "$IMG" --client "$R2_ADMIN_URL" --quiet --eval 'printjson(rs.conf())'

echo "Cluster status:"
docker run --rm -i "${IP_ARGS[@]}" "$IMG" --client "$R2_ADMIN_URL" --quiet --eval 'printjson(rs.status())'
