@echo off
REM ============================================================================
REM run_sim_batch.bat - ModelSim batch (no GUI) simulation for 1024-point FFT
REM ============================================================================
REM Usage: Double-click or run from command line. Results printed to console.
REM        Faster than GUI mode, suitable for regression testing.
REM ============================================================================

echo ============================================
echo  1024-Point FFT - ModelSim Batch Simulation
echo ============================================
echo.

cd /d "%~dp0"

if exist work rmdir /s /q work

copy /y "..\rtl\twiddle_init.hex" "twiddle_init.hex" >nul

vlib work >nul 2>&1
if errorlevel 1 (
    echo [ERROR] vlib failed. Is ModelSim in your PATH?
    pause
    exit /b 1
)
vmap work work >nul 2>&1

echo [INFO] Compiling...
vlog -work work ..\rtl\butterfly.v ..\rtl\twiddle_rom.v ..\rtl\fft_1024_top.v ..\sim\fft_1024_tb.v
if errorlevel 1 ( echo [ERROR] Compilation failed! & pause & exit /b 1 )

echo [INFO] Running simulation (batch mode)...
echo.
vsim -t 1ps -c -voptargs="+acc" work.fft_1024_tb -do "run -all; quit -f"

echo.
echo ============================================
echo  Simulation complete.
echo ============================================
pause
