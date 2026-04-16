@echo off
REM ============================================================================
REM run_sim.bat - One-click ModelSim simulation for 1024-point FFT
REM ============================================================================
REM Usage: Double-click this file, or run from command line.
REM        Make sure ModelSim (vsim) is in your system PATH.
REM ============================================================================

echo ============================================
echo  1024-Point FFT - ModelSim Simulation
echo ============================================
echo.

REM --- Change to the sim directory (same folder as this .bat) ---
cd /d "%~dp0"

REM --- Launch ModelSim GUI and execute the do script ---
REM    run_modelsim.do handles: compile, load, add waves, run
vsim -do run_modelsim.do

echo.
echo [INFO] ModelSim closed.
pause
