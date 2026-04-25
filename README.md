# r369-monitoring-dashboard
Quick and Easy Single File Install for a Live Web-Based Dashboard, Floating Terminal, and System Control for Linux Servers

* Upload the file 'r369-monitor-installer.sh' to any folder (ie, /opt).
* chmod +xs r369-monitor-installer.sh
* bash r369-monitor-installer.sh

This downloads/installs pre-requisite files and installs the simple application including embedded Python web service to run on port 10369 (20369 is used if 10369 is in use as fallback), sets to auto-start the service at reboot, saves logs under FOLDER/r369/logs, and is ready to go! Visit the host/IP:10369 to load your R369 Monitoring Dashboard.
