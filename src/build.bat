@echo off
rem Builds Rebalance's dlls\main.dll: craft from nearby storage + hosts the
rem SurvivalTweaks binary (see main.cpp).
setlocal
set ROOT=%~dp0..
set OUT=%ROOT%\Permafrost\Binaries\Win64\ue4ss\Mods\Rebalance
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist "%OUT%\dlls" mkdir "%OUT%\dlls"
if not exist "%~dp0obj" mkdir "%~dp0obj"
cl /nologo /std:c++17 /O2 /MD /EHsc /W4 /bigobj /DUNICODE /D_UNICODE /LD "%~dp0main.cpp" /Fo"%~dp0obj\\" /Fe"%OUT%\dlls\main.dll" /link /NOLOGO /PDB:"%~dp0obj\main.pdb" /IMPLIB:"%~dp0obj\main.lib" || exit /b 1
del "%OUT%\dlls\main.exp" 2>nul
if not exist "%OUT%\enabled.txt" type nul > "%OUT%\enabled.txt"
echo built %OUT%
