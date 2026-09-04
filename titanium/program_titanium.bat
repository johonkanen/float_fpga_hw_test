@echo off
call "D:\Efinity\2026.1\bin\setup.bat"
cd /d "%~dp0"
call efx_run.bat hfloat_test.xml --flow program --pgm_opts mode=jtag
echo PROG_EXITCODE=%ERRORLEVEL%
