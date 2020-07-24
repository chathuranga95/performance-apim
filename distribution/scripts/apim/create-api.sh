#!/bin/bash -e
# Copyright 2017 WSO2 Inc. (http://wso2.org)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ----------------------------------------------------------------------------
# Create APIs in WSO2 API Manager
# ----------------------------------------------------------------------------

script_dir=$(dirname "$0")
apim_host=""
api_name=""
api_description=""
backend_endpoint_url=""
default_backend_endpoint_type="http"
backend_endpoint_type="$default_backend_endpoint_type"
out_sequence=""
token_type="JWT"

function usage() {
    echo ""
    echo "Usage: "
    echo "$0 -a <apim_host> -n <api_name> -d <api_description> -b <backend_endpoint_url>"
    echo "   [-t <backend_endpoint_type>] [-o <out_sequence>] [-h]"
    echo ""
    echo "-a: Hostname of WSO2 API Manager."
    echo "-n: API Name."
    echo "-d: API Description."
    echo "-b: Backend endpoint URL."
    echo "-t: Backend endpoint type. Default: $default_backend_endpoint_type."
    echo "-o: Out Sequence."
    echo "-k: Token type."
    echo "-h: Display this help and exit."
    echo ""
}

while getopts "a:n:d:b:t:o:k:h" opt; do
    case "${opt}" in
    a)
        apim_host=${OPTARG}
        ;;
    n)
        api_name=${OPTARG}
        ;;
    d)
        api_description=${OPTARG}
        ;;
    b)
        backend_endpoint_url=${OPTARG}
        ;;
    t)
        backend_endpoint_type=${OPTARG}
        ;;
    o)
        out_sequence=${OPTARG}
        ;;
    k)
        token_type=${OPTARG}
        ;;
    h)
        usage
        exit 0
        ;;
    \?)
        usage
        exit 1
        ;;
    *)
        opts+=("-${opt}")
        [[ -n "$OPTARG" ]] && opts+=("$OPTARG")
        ;;
    esac
done
shift "$((OPTIND - 1))"

if [[ -z $apim_host ]]; then
    echo "Please provide the Hostname of WSO2 API Manager."
    exit 1
fi

if [[ -z $api_name ]]; then
    echo "Please provide the API Name."
    exit 1
fi

if [[ -z $api_description ]]; then
    echo "Please provide the API description."
    exit 1
fi

if [[ -z $backend_endpoint_url ]]; then
    echo "Please provide the backend endpoint URL."
    exit 1
fi

if [[ -z $backend_endpoint_type ]]; then
    echo "Please provide the backend endpoint type."
    exit 1
fi

base_https_url="https://${apim_host}:9443"
nio_https_url="https://${apim_host}:8243"

curl_command="curl -sk"

#Check whether jq command exsits
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq."
    exit 1
fi

confirm() {
    # call with a prompt string or use a default
    read -r -p "${1:-Are you sure?} [y/N] " response
    case $response in
    [yY][eE][sS] | [yY])
        true
        ;;
    *)
        false
        ;;
    esac
}

# Register Client and Get Access Token
client_request() {
    cat <<EOF
{
    "callbackUrl": "wso2.org",
    "clientName": "setup_apim_script",
    "tokenScope": "Production",
    "owner": "admin",
    "grantType": "password refresh_token",
    "saasApp": true
}
EOF
}

# Create application request payload
app_request() {
    cat <<EOF
{ 
   "name":"PerformanceTestAPP",
   "throttlingPolicy":"Unlimited",
   "description":"PerformanceTestAPP",
   "attributes":{ 
   }
}
EOF
}

client_credentials=$($curl_command -u admin:admin -H "Content-Type: application/json" -d "$(client_request)" ${base_https_url}/client-registration/v0.17/register | jq -r '.clientId + ":" + .clientSecret')

# Find "PerformanceTestAPP" ID
echo "Getting PerformanceTestAPP ID"
application_id=$($curl_command "${base_https_url}/api/am/store/v1/applications?query=PerformanceTestAPP" | jq -r '.list[0] | .applicationId')
if [ ! -z $application_id ] && [ ! $application_id = "null" ]; then
    echo "Found application id for \"PerformanceTestAPP\": $application_id"
else
    echo "Creating \"PerformanceTestAPP\" application"
    application_id=$($curl_command -X POST -H "Content-Type: application/json" -d "$(app_request)" "${base_https_url}/api/am/store//applications" | jq -r '.applicationId')
    if [ ! -z $application_id ] && [ ! $application_id = "null" ]; then
        echo "Found application id for \"PerformanceTestAPP\": $application_id"
    else
        echo "Failed to find application id for \"PerformanceTestAPP\""
        exit 1
    fi
fi

echo -ne "\n"

#Write application id to file
echo $application_id >"$script_dir/target/application_id"
echo -ne "\n"

# Create APIs
api_create_request() {
    cat <<EOF
{
   "name":"$1",
   "description":"$2",
   "context":"/$1",
   "version":"1.0.0",
   "provider":"admin",
   "policies":[
      "Unlimited"
   ],
   "endpointConfig":{
      "endpoint_type":"${backend_endpoint_type}",
      "sandbox_endpoints":{
         "url":"${backend_endpoint_url}"
      },
      "production_endpoints":{
         "url":"${backend_endpoint_url}"
      }
   },
   "gatewayEnvironments":[
      "Production and Sandbox"
   ],
   "operations":[
      {
         "target":"/*",
         "verb":"POST",
         "authType":"None",
         "throttlingPolicy":"Unlimited"
      }
   ]
}
EOF
}

mediation_policy_request() {
    cat <<EOF
{
    "name": "mediation-api-sequence",
    "type": "out",
    "config": "$1"
}
EOF
}

subscription_request() {
    cat <<EOF
{
   "apiId":"$1",
   "applicationId":"$application_id",
   "throttlingPolicy":"Unlimited"
}
EOF
}

create_api() {
    local api_name="$1"
    local api_desc="$2"
    local out_sequence="$3"
    echo "Creating $api_name API..."
    # Check whether API exists
    local existing_api_id=$($curl_command ${base_https_url}/api/am/publisher/v1/apis?query=name:$api_name\$ | jq -r '.list[0] | .id')
    if [ ! -z $existing_api_id ] && [ ! $existing_api_id = "null" ]; then
        echo "$api_name API already exists with ID $existing_api_id"
        echo -ne "\n"
        if (confirm "Delete $api_name API?"); then
            # Check subscriptions first
            local subscription_id=$($curl_command "${base_https_url}/api/am/store/v1/subscriptions?apiId=$existing_api_id" | jq -r '.list[0] | .subscriptionId')
            if [ ! -z $subscription_id ] && [ ! $subscription_id = "null" ]; then
                echo "Subscription found for $api_name API. Subscription ID is $subscription_id"
                # Delete subscription
                local delete_subscription_status=$($curl_command -w "%{http_code}" -o /dev/null -X DELETE "${base_https_url}/api/am/store/v1/subscriptions/$subscription_id")
                if [ $delete_subscription_status -eq 200 ]; then
                    echo "Subscription $subscription_id deleted!"
                    echo -ne "\n"
                else
                    echo "Failed to delete subscription $subscription_id"
                    echo -ne "\n"
                    return
                fi
            else
                echo "No suscriptions found for $api_name API"
                echo -ne "\n"
            fi

            local delete_api_status=$($curl_command -w "%{http_code}" -o /dev/null -X DELETE "${base_https_url}/api/am/publisher/v1/apis/$existing_api_id")
            if [ $delete_api_status -eq 200 ]; then
                echo "$api_name API deleted!"
                echo -ne "\n"
            else
                echo "Failed to delete $api_name API"
                echo -ne "\n"
                return
            fi
        else
            return
        fi
    fi
    local api_id=$($curl_command -H "Content-Type: application/json" -d "$(api_create_request $api_name $api_desc)" ${base_https_url}/api/am/publisher/v1/apis | jq -r '.id')
    if [ ! -z $api_id ] && [ ! $api_id = "null" ]; then
        echo "Created $api_name API with ID $api_id"
        echo -ne "\n"
    else
        echo "Failed to create $api_name API"
        echo -ne "\n"
        return
    fi
    echo "Publishing $api_name API"
    local publish_api_status=$($curl_command -w "%{http_code}" -o /dev/null -X POST "${base_https_url}/api/am/publisher/v1/apis/change-lifecycle?action=Publish&apiId=${api_id}")
    if [ $publish_api_status -eq 200 ]; then
        echo "$api_name API Published!"
        echo -ne "\n"
    else
        echo "Failed to publish $api_name API"
        echo -ne "\n"
        return
    fi
    if [ ! -z "$out_sequence" ]; then
        echo "Adding mediation policy to $api_name API"
        local sequence_id=$($curl_command -F type=out -F mediationPolicyFile=@$script_dir/payload/mediation-api-sequence.xml "${base_https_url}/api/am/publisher/v1/apis/${api_id}/mediation-policies" | jq -r '.id')
        if [ ! -z $sequence_id ] && [ ! $sequence_id = "null" ]; then
            echo "Mediation policy added to $api_name API with ID $sequence_id"
            echo -ne "\n"
        else
            echo "Failed to add mediation policy to $api_name API"
            echo -ne "\n"
            return
        fi
        echo "Updating $api_name API to set mediation policy..."
        local api_details=""
        n=0
        until [ $n -ge 50 ]; do
            sleep 10
            #Get API
            api_details="$($curl_command "${base_https_url}/api/am/publisher/v1/apis/${api_id}" || echo "")"
            if [ -n "$api_details" ]; then
                # Update API with sequence
                echo "Updating $api_name API to set mediation policy..."
                api_details=$(echo "$api_details" | jq -r '.mediationPolicies |= [{"name":"mediation-api-sequence","type":"out"}]')
                break
            fi
            n=$(($n + 1))
        done
        n=0
        until [ $n -ge 50 ]; do
            sleep 10
            local updated_api="$($curl_command -H "Content-Type: application/json" -X PUT -d "$api_details" "${base_https_url}/api/am/publisher/v1/apis/${api_id}")"
            local updated_api_id=$(echo "$updated_api" | jq -r '.id')
            if [ ! -z $updated_api_id ] && [ ! $updated_api_id = "null" ]; then
                echo "Mediation policy is set to $api_name API with ID $updated_api_id"
                break
            fi
            n=$(($n + 1))
        done
        if [ -z $updated_api_id ] || [ $updated_api_id = "null" ]; then
            echo "Failed to set mediation policy to $api_name API"
            return 1
        fi
    fi
    echo "Subscribing $api_name API to PerformanceTestAPP"
    local subscription_id=$($curl_command -H "Content-Type: application/json" -d "$(subscription_request $api_id)" "${base_https_url}/api/am/store/v1/subscriptions" | jq -r '.subscriptionId')
    if [ ! -z $subscription_id ] && [ ! $subscription_id = "null" ]; then
        echo "Successfully subscribed $api_name API to PerformanceTestAPP. Subscription ID is $subscription_id"
        echo -ne "\n"
    else
        echo "Failed to subscribe $api_name API to PerformanceTestAPP"
        echo -ne "\n"
        return
    fi
}

create_api "$api_name" "$api_description" "$out_sequence"
