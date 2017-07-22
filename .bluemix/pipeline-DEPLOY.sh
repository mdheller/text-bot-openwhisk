#!/bin/bash

###############################################
# Install dependencies
###############################################

echo 'Installing dependencies...'
sudo apt-get -qq update 1>/dev/null
sudo apt-get -qq install jq 1>/dev/null
sudo apt-get -qq install figlet 1>/dev/null

figlet 'Node.js'

echo 'Installing nvm (Node.js Version Manager)...'
npm config delete prefix
curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.31.2/install.sh | bash > /dev/null 2>&1
. ~/.nvm/nvm.sh

echo 'Installing Node.js 7.9.0...'
nvm install 7.9.0 1>/dev/null
npm install --progress false --loglevel error 1>/dev/null

figlet 'OpenWhisk CLI'
mkdir ~/wsk
curl https://openwhisk.ng.bluemix.net/cli/go/download/linux/amd64/wsk > ~/wsk/wsk
chmod +x ~/wsk/wsk
export PATH=$PATH:~/wsk

################################################
# Create Services
################################################
figlet 'Services'

# Create Cloudant Service
figlet -f small 'Cloudant'
cf create-service cloudantNoSQLDB Lite cloudant-openwhisk
cf create-service-key cloudant-openwhisk cloudant-key

CLOUDANT_CREDENTIALS=`cf service-key cloudant-openwhisk cloudant-key | tail -n +2`
export CLOUDANT_USERNAME=`echo $CLOUDANT_CREDENTIALS | jq -r .username`
export CLOUDANT_PASSWORD=`echo $CLOUDANT_CREDENTIALS | jq -r .password`
export CLOUDANT_HOST=`echo $CLOUDANT_CREDENTIALS | jq -r .host`
#Cloudant database should be set by the pipeline, else use a default
if [ -z "$CLOUDANT_DB" ]; then
    echo 'CLOUDANT_DB was not set in the pipeline. Using a default value.'
    export CLOUDANT_DB=whiskbotdb
fi

echo 'Creating '$CLOUDANT_DB' database...'
# ignore the "database already exists error
curl -s -X PUT "https://$CLOUDANT_USERNAME:$CLOUDANT_PASSWORD@$CLOUDANT_HOST/$CLOUDANT_DB"

# Create Watson Natural Language Understanding Service
figlet -f small 'Natural Language Understanding'
cf create-service natural-language-understanding free nlu-openwhisk
cf create-service-key nlu-openwhisk nlu-key

NLU_CREDENTIALS=`cf service-key nlu-openwhisk nlu-key | tail -n +2`
export NLU_USERNAME=`echo $NLU_CREDENTIALS | jq -r .username`
export NLU_PASSWORD=`echo $NLU_CREDENTIALS | jq -r .password`
export NLU_URL=`echo $NLU_CREDENTIALS | jq -r .url`

# Create Watson Conversation Service
figlet -f small	'Conversation'
cf create-service conversation free conversation-openwhisk
cf create-service-key conversation-openwhisk conversation-key
cd .bluemix

CONVERSATION_CREDENTIALS=`cf service-key conversation-openwhisk conversation-key | tail -n +2`
export CONVERSATION_USERNAME=`echo $CONVERSATION_CREDENTIALS | jq -r .username`
export CONVERSATION_PASSWORD=`echo $CONVERSATION_CREDENTIALS | jq -r .password`
CONVERSATION_WORKSPACE=`cat workspace.json`
CONVERSATION_WORKSPACE_INTENTS=`echo $CONVERSATION_WORKSPACE | jq -r .intents`
CONVERSATION_WORKSPACE_ENTITIES=`echo $CONVERSATION_WORKSPACE | jq -r .entities`
CONVERSATION_WORKSPACE_DIALOG_NODES=`echo $CONVERSATION_WORKSPACE | jq -r .dialog_nodes`
export CONVERSATION_WORKSPACE_ID=`curl -H "Content-Type: application/json" -X POST \
-u $CONVERSATION_USERNAME:$CONVERSATION_PASSWORD \
-d "{\"name\":\"Sample\",\"intents\":$CONVERSATION_WORKSPACE_INTENTS,\"entities\":$CONVERSATION_WORKSPACE_ENTITIES,\"language\":\"en\",\"description\":\"The Watson Weather Bot\",\"dialog_nodes\":$CONVERSATION_WORKSPACE_DIALOG_NODES}" \
"https://gateway.watsonplatform.net/conversation/api/v1/workspaces?version=2017-05-26" | jq -r .workspace_id`
cd ..

# Create Weather Insights service
figlet -f small 'weatherinsights'
cf create-service weatherinsights Free-v2 weatherinsights-openwhisk
cf create-service-key weatherinsights-openwhisk weatherinsights-key

WEATHER_CREDENTIALS=`cf service-key weatherinsights-openwhisk weatherinsights-key | tail -n +2`
export WEATHER_USERNAME=`echo $WEATHER_CREDENTIALS | jq -r .username`
export WEATHER_PASSWORD=`echo $WEATHER_CREDENTIALS | jq -r .password`
export WEATHER_URL=`echo $WEATHER_CREDENTIALS | jq -r .url`

################################################################
# OpenWhisk artifacts
################################################################
figlet 'OpenWhisk'

echo 'Retrieving OpenWhisk authorization key...'

# Retrieve the OpenWhisk authorization key
CF_ACCESS_TOKEN=`cat ~/.cf/config.json | jq -r .AccessToken | awk '{print $2}'`

# Docker image should be set by the pipeline, use a default if not set
if [ -z "$OPENWHISK_API_HOST" ]; then
  echo 'OPENWHISK_API_HOST was not set in the pipeline. Using default value.'
  export OPENWHISK_API_HOST=openwhisk.ng.bluemix.net
fi
OPENWHISK_KEYS=`curl -XPOST -k -d "{ \"accessToken\" : \"$CF_ACCESS_TOKEN\", \"refreshToken\" : \"$CF_ACCESS_TOKEN\" }" \
  -H 'Content-Type:application/json' https://$OPENWHISK_API_HOST/bluemix/v2/authenticate`

SPACE_KEY=`echo $OPENWHISK_KEYS | jq -r '.namespaces[] | select(.name == "'$CF_ORG'_'$CF_SPACE'") | .key'`
SPACE_UUID=`echo $OPENWHISK_KEYS | jq -r '.namespaces[] | select(.name == "'$CF_ORG'_'$CF_SPACE'") | .uuid'`
OPENWHISK_AUTH=$SPACE_UUID:$SPACE_KEY

# Configure the OpenWhisk CLI
wsk property set --apihost $OPENWHISK_API_HOST --auth "${OPENWHISK_AUTH}"

# To enable the creation of API in Bluemix, inject the CF token in the wsk properties
echo "APIGW_ACCESS_TOKEN=${CF_ACCESS_TOKEN}" >> ~/.wskprops

###############################################
# OpenWhisk Actions
###############################################
echo 'Creating the OpenWhisk actions...'
export PACKAGE="openwhisk-weather-bot"
wsk package create openwhisk-weather-bot
wsk action create $PACKAGE/cloudant-add actions/cloudant-add.js
wsk action create $PACKAGE/cloudant-read actions/cloudant-read.js
wsk action create $PACKAGE/cloudant-write actions/cloudant-write.js
wsk action create $PACKAGE/conversation1 actions/conversation.js
wsk action create $PACKAGE/conversation2 actions/conversation-weather.js
wsk action create $PACKAGE/nlu actions/nlu.js
wsk action create $PACKAGE/getGeoLoc actions/getGeoLoc.js
wsk action create $PACKAGE/getWeather actions/getWeather.js

echo 'Setting default parameters...'
wsk action update $PACKAGE/cloudant-add --param username $CLOUDANT_USERNAME --param password $CLOUDANT_PASSWORD --param workspace_id $CLOUDANT_HOST
wsk action update $PACKAGE/cloudant-read --param username $CLOUDANT_USERNAME --param password $CLOUDANT_PASSWORD --param workspace_id $CLOUDANT_HOST
wsk action update $PACKAGE/cloudant-write --param username $CLOUDANT_USERNAME --param password $CLOUDANT_PASSWORD --param workspace_id $CLOUDANT_HOST
wsk action update $PACKAGE/nlu --param username $NLU_USERNAME --param password $NLU_PASSWORD
wsk action update $PACKAGE/conversation1 --param username $CONVERSATION_USERNAME --param password $CONVERSATION_PASSWORD --param workspace_id $CONVERSATION_WORKSPACE_ID
wsk action update $PACKAGE/conversation2 --param username $CONVERSATION_USERNAME --param password $CONVERSATION_PASSWORD --param workspace_id $CONVERSATION_WORKSPACE_ID
wsk action update $PACKAGE/getGeoLoc --param username $WEATHER_USERNAME --param password $WEATHER_PASSWORD --param url $WEATHER_URL
wsk action update $PACKAGE/getWeather --param username $WEATHER_USERNAME --param password $WEATHER_PASSWORD --param url $WEATHER_URL

echo 'Creating OpenWhisk Sequence...'
wsk action create openwhisk-weather-bot-sequence --sequence /$PACKAGE/nlu,/$PACKAGE/getGeoLoc,/$PACKAGE/conversation1,/$PACKAGE/getWeather,/$PACKAGE/conversation2

echo 'Creating OpenWhisk API'
wsk api create /openwhisk-weather-bot-api /submit POST $PACKAGE/openwhisk-weather-bot-sequence --response-type json
API_URL='wsk api get /openwhisk-weather-bot-api -f | jq -r .gwApiUrl'
API_URL+="/submit"
export REACT_APP_API_URL=$API_URL
