@echo off
:: Ansys Elastic Licence Monitor - manual trigger (debug builds only).
:: Drops a sentinel file the agent loop picks up next iteration and re-runs
:: the compliance check immediately. Quiet (no console output to the user).
type nul > "%LOCALAPPDATA%\AnsysElasticLicenceMonitor\trigger-check.flag"
