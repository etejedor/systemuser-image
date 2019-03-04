#!/bin/sh

echo "Configuring user session"

# Make sure the user has the SWAN_projects folder
SWAN_PROJECTS=$SWAN_HOME/SWAN_projects/
mkdir -p $SWAN_PROJECTS

# Persist enabled notebook nbextensions
NBCONFIG=$JPY_DIR/nbconfig
mkdir -p $NBCONFIG
LOCAL_NB_NBEXTENSIONS=$SWAN_PROJECTS/.notebook_nbextensions
if [ ! -f $LOCAL_NB_NBEXTENSIONS ]; then 
  echo "{
    \"load_extensions\": {
    }
  }" > $LOCAL_NB_NBEXTENSIONS
fi
rm -f $NBCONFIG/notebook.json
ln -s $LOCAL_NB_NBEXTENSIONS $NBCONFIG/notebook.json

# Setup LCG
source $LCG_VIEW/setup.sh

# Add SWAN modules path to PYTHONPATH so that it picks them
export PYTHONPATH=/usr/local/lib/swan/extensions/:$PYTHONPATH 

# To prevent conflicts with older versions of Jupyter dependencies in CVMFS
# add these packages to the beginning of PYTHONPATH
if [[ $PYVERSION -eq 3 ]]; 
then 
 export PYTHONPATH=/usr/local/lib/swan/:$PYTHONPATH
fi 

# Configure SparkMonitor
export KERNEL_PROFILEPATH=$PROFILEPATH/ipython_kernel_config.py 
echo "c.InteractiveShellApp.extensions.append('sparkmonitor.kernelextension')" >>  $KERNEL_PROFILEPATH

# Configure SparkConnector
if [[ $SPARK_CLUSTER_NAME ]]; 
then
 echo "Configuring environment for Spark cluster: $SPARK_CLUSTER_NAME"
 source $SPARK_CONFIG_SCRIPT $SPARK_CLUSTER_NAME
 export SPARK_LOCAL_IP=`hostname -i`
 echo "c.InteractiveShellApp.extensions.append('sparkconnector.connector')" >>  $KERNEL_PROFILEPATH
 if [[ $CONNECTOR_BUNDLED_CONFIGS ]]
  then
    ln -s $CONNECTOR_BUNDLED_CONFIGS/bundles.json $JUPYTER_CONFIG_DIR/nbconfig/sparkconnector_bundles.json
    ln -s $CONNECTOR_BUNDLED_CONFIGS/spark_options.json $JUPYTER_CONFIG_DIR/nbconfig/sparkconnector_spark_options.json
  fi
 echo "Completed Spark Configuration"
fi

# Run user startup script
export JUPYTER_DATA_DIR=$LCG_VIEW/share/jupyter 
export TMP_SCRIPT=`mktemp`

if [[ $USER_ENV_SCRIPT && -f `eval echo $USER_ENV_SCRIPT` ]]; 
then
 echo "Found user script: $USER_ENV_SCRIPT"
 export TMP_SCRIPT=`mktemp`
 cat `eval echo $USER_ENV_SCRIPT` > $TMP_SCRIPT
 source $TMP_SCRIPT
else
 echo "Cannot find user script: $USER_ENV_SCRIPT";
fi

# Configure kernels
# As the LCG setup might set PYTHONHOME, run python with -E to prevent this python 2 code
# to lookup for modules in a Python 3 path (if this is the selected stack)
/usr/local/bin/python3 -E <<EOF
import os, re
import json

def addEnv(dtext):
    d=eval(dtext)
    d["env"]=dict(os.environ)
    return d

kdirs = os.listdir("$KERNEL_DIR")
kfile_names = ["$KERNEL_DIR/%s/kernel.json" % kdir for kdir in kdirs]
kfile_contents = [open(kfile_name).read() for kfile_name in kfile_names]
kfile_contents_mod = list(map(addEnv, kfile_contents))
print(kfile_contents_mod)
[open(d[0],"w").write(json.dumps(d[1])) for d in zip(kfile_names,kfile_contents_mod)]

with open("$SWAN_ENV_FILE", "w") as termEnvFile:
    for key, val in dict(os.environ).items():
        if key == "SUDO_COMMAND":
            continue
        if key == "PYTHONPATH":
            val = re.sub('/usr/local/lib/swan/(extensions/)?:', '', val)
        termEnvFile.write("export %s=\"%s\"\n" % (key, val))
EOF

# Make sure that `python` points to the correct python bin from CVMFS
printf "alias python=\"$(which python$PYVERSION)\"\n" >> $SWAN_ENV_FILE

# Remove our extra paths (where we install our extensions) in the kernel (via SwanKernelEnv kernel extension), 
# leaving the user env cleaned. It should be the last one called to allow the kernel to load our extensions correctly.
echo "c.InteractiveShellApp.extensions.append('swankernelenv')" >>  $KERNEL_PROFILEPATH