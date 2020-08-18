#!/bin/bash
################################################################################
# Configure Glassfish
#
# BEWARE: As this is done for Kubernetes, we will ALWAYS start with a fresh container!
#         When moving to Glassfish/Payara 5+ the option commands are idempotent.
#         The resources are to be created by the application on deployment,
#         once Dataverse has proper refactoring, etc.
#         See upstream issue IQSS/dataverse#5292
################################################################################

# Fail on any error
set -e
# Include some sane defaults
. ${SCRIPT_DIR}/default.config

# 0. Define postboot commands file to be read by Payara and clear it
DV_POSTBOOT=${PAYARA_DIR}/dataverse_postboot
echo "# Dataverse postboot configuration for Payara" > ${DV_POSTBOOT}

# 1. Password aliases from secrets
# TODO: This is ugly and dirty. It leaves leftovers on the filesystem.
#       It should be replaced by using proper config mechanisms sooner than later,
#       like MicroProfile Config API.
for alias in rserve doi db
do
  if [ -f ${SECRETS_DIR}/$alias/password ]; then
    echo "INFO: Defining password alias for $alias"
    cat ${SECRETS_DIR}/$alias/password | sed -e "s#^#AS_ADMIN_ALIASPASSWORD=#" > ${SECRETS_DIR}/${alias}_asadmin
    echo "create-password-alias dataverse.${alias}.password --passwordfile ${SECRETS_DIR}/${alias}_asadmin" >> ${DV_POSTBOOT}
  else
    echo "WARNING: Could not find 'password' secret for ${alias} in ${SECRETS_DIR}. Check your Kubernetes Secrets and their mounting!"
  fi
done

# 1b. Create AWS access credentials when storage driver is set to s3
#     See IQSS/dataverse-kubernetes#28 for details of this workaround.
if [ "s3" = "${dataverse_files_storage__driver__id}" ]; then
  if [ -f ${SECRETS_DIR}/s3/access-key ] && [ -f ${SECRETS_DIR}/s3/secret-key ]; then
    echo "INFO: Deploying AWS credentials."
    mkdir -p ${HOME_DIR}/.aws
    echo "[default]" > ${HOME_DIR}/.aws/credentials
    cat ${SECRETS_DIR}/s3/access-key | sed -e "s#^#aws_access_key_id = #" -e "s#\$#\n#" >> ${HOME_DIR}/.aws/credentials
    cat ${SECRETS_DIR}/s3/secret-key | sed -e "s#^#aws_secret_access_key = #" -e "s#\$#\n#" >> ${HOME_DIR}/.aws/credentials
  else
    echo "WARNING: Could not find all S3 access secrets in ${SECRETS_DIR}/s3/(access-key|secret-key). Check your Kubernetes Secrets and their mounting!"
  fi
fi

# 2. Domain-spaced resources (JDBC, JMS, ...)
# TODO: This is ugly and dirty. It should be replaced with resources from
#       EE 8 code annotations or at least glassfish-resources.xml
# NOTE: postboot commands is not multi-line capable, thus spaghetti needed.

# JMS
echo "INFO: Defining JMS resources."
cat >> ${DV_POSTBOOT} << 'EOF'
delete-connector-connection-pool --cascade=true jms/__defaultConnectionFactory-Connection-Pool
create-connector-connection-pool --steadypoolsize=1 --maxpoolsize=250 --poolresize=2 --maxwait=60000 --raname=jmsra --connectiondefinition=javax.jms.QueueConnectionFactory jms/IngestQueueConnectionFactoryPool
create-connector-resource --poolname=jms/IngestQueueConnectionFactoryPool jms/IngestQueueConnectionFactory
create-admin-object --restype=javax.jms.Queue --raname=jmsra --property=Name=DataverseIngest jms/DataverseIngest
EOF

# JDBC
#echo "INFO: Defining JDBC resources."
#echo "create-jdbc-connection-pool --restype=javax.sql.DataSource --datasourceclassname=org.postgresql.ds.PGPoolingDataSource --property=create=true:User=${POSTGRES_USER}:PortNumber=${POSTGRES_PORT}:databaseName=${POSTGRES_DATABASE}:ServerName=${POSTGRES_SERVER} dvnDbPool" >> ${DV_POSTBOOT}
#echo 'set resources.jdbc-connection-pool.dvnDbPool.property.password=${ALIAS=db_password_alias}' >> ${DV_POSTBOOT}
#echo "create-jdbc-resource --connectionpoolid=dvnDbPool jdbc/VDCNetDS" >> ${DV_POSTBOOT}
echo "create-system-properties dataverse.db.user=${POSTGRES_USER}" >> ${DV_POSTBOOT}
echo "create-system-properties dataverse.db.host=${POSTGRES_SERVER}" >> ${DV_POSTBOOT}
echo "create-system-properties dataverse.db.port=${POSTGRES_PORT}" >> ${DV_POSTBOOT}
echo "create-system-properties dataverse.db.name=${POSTGRES_DATABASE}" >> ${DV_POSTBOOT}

# JavaMail
echo "INFO: Defining JavaMail."
echo "create-javamail-resource --mailhost=${MAIL_SERVER} --mailuser=dataversenotify --fromaddress=${MAIL_FROMADDRESS} mail/notifyMailSession" >> ${DV_POSTBOOT}

echo "INFO: defining miscellaneous configuration options."
# Timer data source
echo "set configs.config.server-config.ejb-container.ejb-timer-service.timer-datasource=java:global/jdbc/dataverse" >> ${DV_POSTBOOT}
# AJP connector
echo "create-network-listener --protocol=http-listener-1 --listenerport=8009 --jkenabled=true jk-connector" >> ${DV_POSTBOOT}
# Disable logging for grizzly SSL problems -- commented out as this is not GF 4.1
# echo "set-log-levels org.glassfish.grizzly.http.server.util.RequestUtils=SEVERE" >> ${DV_POSTBOOT}
# COMET support
echo "set server-config.network-config.protocols.protocol.http-listener-1.http.comet-support-enabled=true" >> ${DV_POSTBOOT}
# SAX parser options
echo "create-system-properties javax.xml.parsers.SAXParserFactory=com.sun.org.apache.xerces.internal.jaxp.SAXParserFactoryImpl" >> ${DV_POSTBOOT}

# 3. Domain based configuration options
# Set Dataverse environment variables
echo "INFO: Defining system properties for Dataverse configuration options."
#env | grep -Ee "^(dataverse|doi)_" | sort -fd
env -0 | grep -z -Ee "^(dataverse|doi)_" | while IFS='=' read -r -d '' k v; do
    # transform __ to -
    KEY=`echo "${k}" | sed -e "s#__#-#g"`
    # transform remaining single _ to .
    KEY=`echo "${KEY}" | tr '_' '.'`

    # escape colons in values
    v=`echo "${v}" | sed -e 's/:/\\\:/g'`

    echo "DEBUG: Handling ${KEY}=${v}."
    echo "create-system-properties ${KEY}=${v}" >> ${DV_POSTBOOT}
done

# 4. Add the commands to the existing postboot file, but insert BEFORE deployment
echo "$(cat ${DV_POSTBOOT} | cat - ${POSTBOOT_COMMANDS} )" > ${POSTBOOT_COMMANDS}
echo "DEBUG: postboot contains the following commands:"
echo "--------------------------------------------------"
cat ${POSTBOOT_COMMANDS}
echo "--------------------------------------------------"

# 5. Symlink the jHove configuration
echo "INFO: Symlinking and editing jHove configuration."
ln -s ${HOME_DIR}/dvinstall/jhove.conf ${PAYARA_DIR}/glassfish/domains/${DOMAIN_NAME}/config/jhove.conf
ln -s ${HOME_DIR}/dvinstall/jhoveConfig.xsd ${PAYARA_DIR}/glassfish/domains/${DOMAIN_NAME}/config/jhoveConfig.xsd
sed -i ${PAYARA_DIR}/glassfish/domains/${DOMAIN_NAME}/config/jhove.conf -e "s:/usr/local/glassfish4/glassfish/domains/domain1:${PAYARA_DIR}/glassfish/domains/${DOMAIN_NAME}:g"

# 6. Disable phone home. Always.
echo "disable-phome-home" >> ${PREBOOT_COMMANDS}
