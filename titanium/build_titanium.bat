@echo off
rem Build the Titanium (Ti60F225) hfloat_test image with Efinity.
rem Adjust the Efinity path if needed.
call "D:\Efinity\2026.1\bin\setup.bat"
pushd "%~dp0\.."
call pwsh -NoProfile -File write_githash.ps1
popd
cd /d "%~dp0"
call efx_run.bat --prj hfloat_test.xml
echo BUILD_EXITCODE=%ERRORLEVEL%
