#!/bin/sh

# Author: Danilo Piparo, Enric Tejedor 2016
# Copyright CERN
# Here the environment for the notebook server is prepared. Many of the commands are launched as regular 
# user as it's this entity which is able to access eos and not the super user.

# Create notebook user
# The $HOME directory is specified upstream in the Spawner

START_TIME_CONFIGURE_USER_ENV=$( date +%s.%N )

echo "Creating user $USER ($USER_ID) with home $HOME"
export SWAN_HOME=$HOME
if [[ $SWAN_HOME == /eos/* ]]; then export CERNBOX_HOME=$SWAN_HOME; fi
useradd -u $USER_ID -s $SHELL -d $SWAN_HOME $USER
export SCRATCH_HOME=/scratch/$USER
mkdir -p $SCRATCH_HOME
echo "This directory is temporary and will be deleted when your SWAN session ends!" > $SCRATCH_HOME/IMPORTANT.txt
chown -R $USER:$USER $SCRATCH_HOME

echo "Setting directory for Notebook backup"
export USERDATA_PATH=/srv/singleuser/userdata
chown -R $USER:$USER $USERDATA_PATH

# Setup the LCG View on CVMFS
echo "Setting up environment from CVMFS"
export LCG_VIEW=$ROOT_LCG_VIEW_PATH/$ROOT_LCG_VIEW_NAME/$ROOT_LCG_VIEW_PLATFORM

# Set environment for the Jupyter process
echo "Setting Jupyter environment"
export JPY_DIR=$SCRATCH_HOME/.jupyter
mkdir -p $JPY_DIR
JPY_LOCAL_DIR=$SCRATCH_HOME/.local
mkdir -p $JPY_LOCAL_DIR
export JUPYTER_CONFIG_DIR=$JPY_DIR
JUPYTER_LOCAL_PATH=$JPY_LOCAL_DIR/share/jupyter
mkdir -p $JUPYTER_LOCAL_PATH
# Our kernels will be in $JUPYTER_LOCAL_PATH
export JUPYTER_PATH=$JUPYTER_LOCAL_PATH
# symlink $LCG_VIEW/share/jupyter/nbextensions for the notebook extensions
ln -s $LCG_VIEW/share/jupyter/nbextensions $JUPYTER_LOCAL_PATH
export KERNEL_DIR=$JUPYTER_LOCAL_PATH/kernels
mkdir -p $KERNEL_DIR
export JUPYTER_RUNTIME_DIR=$JUPYTER_LOCAL_PATH/runtime
export IPYTHONDIR=$SCRATCH_HOME/.ipython
mkdir -p $IPYTHONDIR
export PROFILEPATH=$IPYTHONDIR/profile_default
mkdir -p $PROFILEPATH
# This avoids to create hardlinks on eos when using pip
export XDG_CACHE_HOME=/tmp/$USER/.cache/
JPY_CONFIG=$JUPYTER_CONFIG_DIR/jupyter_notebook_config.py
echo "c.FileCheckpoints.checkpoint_dir = '$SCRATCH_HOME/.ipynb_checkpoints'"         >> $JPY_CONFIG
echo "c.NotebookNotary.db_file = '$JUPYTER_LOCAL_PATH/nbsignatures.db'"     >> $JPY_CONFIG
echo "c.NotebookNotary.secret_file = '$JUPYTER_LOCAL_PATH/notebook_secret'" >> $JPY_CONFIG
echo "c.NotebookApp.contents_manager_class = 'swancontents.filemanager.swanfilemanager.SwanFileManager'" >> $JPY_CONFIG
echo "c.ContentsManager.checkpoints_class = 'swancontents.filemanager.checkpoints.EOSCheckpoints'" >> $JPY_CONFIG
echo "c.NotebookApp.default_url = 'projects'" >> $JPY_CONFIG
cp -L -r $LCG_VIEW/etc/jupyter/* $JUPYTER_CONFIG_DIR

# Configure %%cpp cell highlighting
CUSTOM_JS_DIR=$JPY_DIR/custom
mkdir $CUSTOM_JS_DIR
echo "
require(['notebook/js/codecell'], function(codecell) {
  codecell.CodeCell.options_default.highlight_modes['magic_text/x-c++src'] = {'reg':[/^%%cpp/]};
});
" > $CUSTOM_JS_DIR/custom.js

# Configure kernels and terminal
# The environment of the kernels and the terminal will combine the view and the user script (if any)
echo "Configuring kernels and terminal"
# Python (2 or 3)
if [ -f $LCG_VIEW/bin/python3 ]; then export PYVERSION=3; else export PYVERSION=2; fi
PYKERNELDIR=$KERNEL_DIR/python$PYVERSION
mkdir -p $PYKERNELDIR
cp -r /usr/local/share/jupyter/kernelsBACKUP/python3/*.png $PYKERNELDIR
echo "{
 \"display_name\": \"Python $PYVERSION\",
 \"language\": \"python\",
 \"argv\": [
  \"python$PYVERSION\",
  \"/usr/local/bin/start_ipykernel.py\",
  \"-f\",
  \"{connection_file}\"
 ]
}" > $PYKERNELDIR/kernel.json
# ROOT
cp -rL $LCG_VIEW/etc/notebook/kernels/root $KERNEL_DIR
# Set Python version in kernel
# In newer stacks the version already comes with it, so the " is necessary to distinguish it
sed -i "s/\"python\"/\"python$PYVERSION\"/g" $KERNEL_DIR/root/kernel.json
# R
cp -rL $LCG_VIEW/share/jupyter/kernels/ir $KERNEL_DIR
sed -i "s/IRkernel::main()/options(bitmapType='cairo');IRkernel::main()/g" $KERNEL_DIR/ir/kernel.json # Force cairo for graphics
# Octave
OCTAVE_KERNEL_PATH=$LCG_VIEW/share/jupyter/kernels/octave
if [[ -d $OCTAVE_KERNEL_PATH ]];
then
   cp -rL $OCTAVE_KERNEL_PATH $KERNEL_DIR
   export OCTAVE_KERNEL_JSON=$KERNEL_DIR/octave/kernel.json
   sed -i "s/python/python$PYVERSION/g" $OCTAVE_KERNEL_JSON # Set Python version in kernel
fi

chown -R $USER:$USER $JPY_DIR $JPY_LOCAL_DIR $IPYTHONDIR
export SWAN_ENV_FILE=/tmp/swan.sh

sudo -E -u $USER sh /srv/singleuser/userconfig.sh

if [ $? -ne 0 ]
then
  echo "Error configuring user environment"
  exit 1
else
  CONFIGURE_USER_ENV_TIME_SEC=$(echo $(date +%s.%N --date="$START_TIME_CONFIGURE_USER_ENV seconds ago") | bc)
  echo "user: $USER, host: ${SERVER_HOSTNAME%%.*}, metric: configure_user_env.duration_sec, value: $CONFIGURE_USER_ENV_TIME_SEC"
fi

START_TIME_CONFIGURE_KERNEL_ENV=$( date +%s.%N )

# Spark configuration
if [[ $SPARK_CLUSTER_NAME ]]
then
  LOCAL_IP=`hostname -i`
  echo "$LOCAL_IP $SERVER_HOSTNAME" >> /etc/hosts

  # Enable the extensions in Jupyter global path to avoid having to maintain this information 
  # in the user scratch json file (specially because now we persist this file in the user directory and
  # we don't want to persist the Spark extensions across sessions)
  mkdir -p /etc/jupyter/nbconfig
  echo "Globally enabling the Spark extensions"
  echo "{
    \"load_extensions\": {
      \"sparkconnector/extension\": true,
      \"hdfsbrowser/extension\": true
    }
  }" > /etc/jupyter/nbconfig/notebook.json
  echo "{
    \"NotebookApp\": {
      \"nbserver_extensions\": {
        \"sparkconnector.portallocator\": true,
        \"hdfsbrowser.serverextension\": true
      }
    }
  }" > /etc/jupyter/jupyter_notebook_config.json
fi

# Configurations for extensions (used when deployed outside CERN)
if [[ $SHARE_CBOX_API_DOMAIN && $SHARE_CBOX_API_BASE ]]
then
  echo "{\"sharing\":
    {
      \"domain\": \"$SHARE_CBOX_API_DOMAIN\",
      \"base\": \"$SHARE_CBOX_API_BASE\",
      \"authentication\": \"/authenticate\",
      \"shared\": \"/sharing\",
      \"shared_with_me\": \"/shared\",
      \"share\": \"/share\",
      \"clone\": \"/clone\",
      \"search\": \"/search\"
  }
}" > /usr/local/etc/jupyter/nbconfig/sharing.json
fi

if [[ $HELP_ENDPOINT ]]
then
  echo "{
    \"help\": \"$HELP_ENDPOINT\"
}" > /usr/local/etc/jupyter/nbconfig/help.json
fi

# Make sure we have a sane terminal
printf "export TERM=xterm\n" >> $SWAN_ENV_FILE

# If there, source users' .bashrc after the SWAN environment
BASHRC_LOCATION=$SWAN_HOME/.bashrc
printf "if [[ -f $BASHRC_LOCATION ]];
then
   source $BASHRC_LOCATION
fi\n" >> $SWAN_ENV_FILE

if [ $? -ne 0 ]
then
  echo "Error setting the environment for kernels"
  exit 1
else
  CONFIGURE_KERNEL_ENV_TIME_SEC=$(echo $(date +%s.%N --date="$START_TIME_CONFIGURE_KERNEL_ENV seconds ago") | bc)
  echo "user: $USER, host: ${SERVER_HOSTNAME%%.*}, metric: configure_kernel_env.duration_sec, value: $CONFIGURE_KERNEL_ENV_TIME_SEC"
fi

# Set the terminal environment
export SWAN_BASH=/bin/swan_bash
printf "#! /bin/env python\nfrom subprocess import call\nimport sys\nexit(call([\"bash\", \"--rcfile\", \"$SWAN_ENV_FILE\"]+sys.argv[1:]))\n" >> $SWAN_BASH
chmod +x $SWAN_BASH

# Allow further configuration by sysadmin (usefull outside of CERN)
if [[ $CONFIG_SCRIPT ]]; 
then
  echo "Found Config script"
  sh $CONFIG_SCRIPT
fi

# Run notebook server
echo "Running the notebook server"
sudo -E -u $USER sh -c '   cd $SWAN_HOME \
                        && SHELL=$SWAN_BASH \
                           jupyterhub-singleuser \
                           --port=8888 \
                           --ip=0.0.0.0 \
                           --user=$JPY_USER \
                           --cookie-name=$JPY_COOKIE_NAME \
                           --base-url=$JPY_BASE_URL \
                           --hub-prefix=$JPY_HUB_PREFIX \
                           --hub-api-url=$JPY_HUB_API_URL'
