#!/usr/bin/env bash

_PASSWORD=${COLDFUSION_ADMIN_PASSWORD:-'Adm1n$'}
_DEFAULT_HOST=${DATASOURCE_HOST:-''}

setConfig () {
  curl --silent -H "X-CF-AdminPassword: ${_PASSWORD}" \
  --data "method=callAPI&wsdl=true&apiComponent=$1&apiMethod=$2&apiArguments=$3" \
  http://127.0.0.1/CFIDE/cfadmin-agent/Gateway.cfc
}

buildDatasource () {
  _DS_TYPE=${DATASOURCE_TYPE:-'setMySQL5'}
  _DS_HOST=${DATASOURCE_HOST:-$_DEFAULT_HOST}
  _DS_USER=${DATASOURCE_USER:-'root'}
  _DS_PASS=${DATASOURCE_PASSWORD:-''}
  _DS_DB=${DATASOURCE_DB:-$DATASOURCE_NAME}

  _ARGS="{"
  _ARGS+="\"host\":\"$_DS_HOST\","
  _ARGS+="\"username\":\"$_DS_USER\","
  _ARGS+="\"password\":\"$_DS_PASS\","
  _ARGS+="\"name\":\"$DATASOURCE_NAME\","
  _ARGS+="\"database\":\"$_DS_DB\""
  if [ ! -z $DATASOURCE_ARGS ]; then
    _ARGS+=",\"args\":\"$DATASOURCE_ARGS\""
  fi
  _ARGS+='}'

  echo ''
  echo "Set datasource: $DATASOURCE_NAME"
  setConfig datasource $_DS_TYPE $_ARGS
  echo ''
}

setJsonVar () {
  if [ ! -z "$2" ] && [ "$2" != "null" ]; then
    eval "${1}=\$$2"
  fi
}

setSN () {
  LICENSE_PATH="/opt/coldfusion10/cfusion/lib/license.properties"
  LICENSE_PATH_TMP="/opt/coldfusion10/cfusion/lib/license.properties-tmp"
  echo ''
  echo "Set Serial number ..."
  echo ''
  cat $LICENSE_PATH | \
  sed -e '/code=/ s/^#*/#/' | \
  sed -e "s/^sn=.*$/sn=$1/" \
  > $LICENSE_PATH_TMP

  cat $LICENSE_PATH_TMP > $LICENSE_PATH
  rm $LICENSE_PATH_TMP
}

setParameters () {
  COLDFUSION_STATUS=`service coldfusion status`
  if [ "$COLDFUSION_STATUS" != "Server is running" ]; then

    echo "Server is not running. Wait..."
    sleep 3
    setParameters

  else

    # Set datasource
    if [ ! -z $DATASOURCE_NAME ]; then
      buildDatasource
    fi

    # set datasources
    if [ ! -z "$DATASOURCES" ]; then
      while read -r _DS
      do
        setJsonVar DATASOURCE_TYPE `echo $_DS | jq 'fromjson | .type'`
        setJsonVar DATASOURCE_HOST `echo $_DS | jq 'fromjson | .host'`
        setJsonVar DATASOURCE_USER `echo $_DS | jq 'fromjson | .username'`
        setJsonVar DATASOURCE_PASSWORD `echo $_DS | jq 'fromjson | .password'`
        setJsonVar DATASOURCE_DB `echo $_DS | jq 'fromjson | .database'`
        _DSNAME=`echo $_DS | jq 'fromjson | .name'`
        if [ "$_DSNAME" != "null" ]; then
          eval "DATASOURCE_NAME=\$$_DSNAME"
        else
          DATASOURCE_NAME=$DATASOURCE_DB
        fi

        buildDatasource
      done < <(echo $DATASOURCES | jq '.[] | tojson')
    fi

    # Set mail server
    if [ ! -z $SMTP_PORT_25_TCP_ADDR ]; then
      echo ''
      echo "Set Mail Server: $SMTP_PORT_25_TCP_ADDR"
      setConfig mail setMailServer "{\"server\": \"$SMTP_PORT_25_TCP_ADDR\"}"
      echo ''
    fi

    # Set scheduler cluster
    if [ ! -z $SCHEDULER_CLUSTER_DSN ]; then
      echo ''
      echo "Set Scheduler cluster: $SCHEDULER_CLUSTER_DSN"
      local _SCHEDULER_CLUSTER_CREATETABLES=${SCHEDULER_CLUSTER_CREATETABLES:-"false"}
      setConfig scheduler setClusterDSNName "{\"dsname\": \"$SCHEDULER_CLUSTER_DSN\",\"createtables\": $_SCHEDULER_CLUSTER_CREATETABLES}"
      echo ''
    fi

  fi
}

_setSessionManager () {
  host=$1
  port=$2
  database=$3

  echo "host=$host"
  echo "port=$port"
  echo "database=$database"

  # Coldfusion
  cat /opt/coldfusion10/cfusion/runtime/conf/context.template.xml | \
    sed "s/REDIS_HOST/$host/" | \
    sed "s/REDIS_PORT/$port/" | \
    sed "s/REDIS_DATABASE/$database/" \
    > /opt/coldfusion10/cfusion/runtime/conf/context.xml

  # PHP
  cat /etc/php5/apache2/php.ini | \
    sed "s/session.save_handler = files/session.save_handler = redis\nsession.save_path = \"tcp:\/\/$host:$port\"\nextension=redis.so/" \
    > /etc/php5/apache2/php.ini.tmp
  mv /etc/php5/apache2/php.ini.tmp /etc/php5/apache2/php.ini
}

setSessionManager () {
  if [ ! -z $REDIS_PORT_6379_TCP_ADDR ]; then
    REDIS_DATABASE=${REDIS_DATABASE:-"0"}
    _setSessionManager $REDIS_PORT_6379_TCP_ADDR $REDIS_PORT_6379_TCP_PORT ${REDIS_DATABASE:-"0"}
  elif [ ! -z $REDIS_HOST ]; then
    REDIS_DATABASE=${REDIS_DATABASE:-"0"}
    REDIS_PORT=${REDIS_PORT:-"6379"}
    _setSessionManager $REDIS_HOST $REDIS_PORT ${REDIS_DATABASE:-"0"}
  else
    echo "Warn: no redis session manager."
  fi
}

setAdminPassword () {
  PASSWORD_PATH="/opt/coldfusion10/cfusion/lib/password.properties"
  PASSWORD_PATH_TMP="/opt/coldfusion10/cfusion/lib/password.properties-tmp"
  echo ''
  echo "Set Admin password ..."
  echo ''
  cat $PASSWORD_PATH | \
  sed -e "s/^password=.*$/password=$1/" | \
  sed -e "s/^encrypted=.*$/encrypted=false/" \
  > $PASSWORD_PATH_TMP

  cat $PASSWORD_PATH_TMP > $PASSWORD_PATH
  rm $PASSWORD_PATH_TMP
}

# Set serial number
if [ ! -z $COLDFUSION_SERIAL_NUMBER ]; then
  setSN $COLDFUSION_SERIAL_NUMBER
fi

# Set admin password
if [ ! -z $COLDFUSION_ADMIN_PASSWORD ]; then
  setAdminPassword $COLDFUSION_ADMIN_PASSWORD
fi

# Set timezone
if [ `cat /etc/timezone` != "$TIMEZONE" ]; then
  echo $TIMEZONE | tee /etc/timezone && dpkg-reconfigure --frontend noninteractive tzdata
fi

# Session manager
setSessionManager

# Start
/sbin/my_init &
echo "Waiting coldfusion start..."

# Set parameters
setParameters

tail -f /var/log/apache2/*.log /opt/coldfusion10/cfusion/logs/*.log &

wait
