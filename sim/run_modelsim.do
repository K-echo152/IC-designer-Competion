#============================================================================
# run_modelsim.do - ModelSim simulation script for 1024-point FFT
#============================================================================
# Usage: In ModelSim, cd to sim/ folder, then: do run_modelsim.do
# Or run via: vsim -do run_modelsim.do
#============================================================================

# Quit any previous simulation (ignore error if none active)
catch {quit -sim}

# Create work library
if {[file exists work]} { vdel -all -lib work }
vlib work
vmap work work

# Compile RTL sources
vlog -work work ../rtl/butterfly.v
vlog -work work ../rtl/twiddle_rom.v
vlog -work work ../rtl/fft_1024_top.v

# Compile testbench
vlog -work work ../sim/fft_1024_tb.v

# Copy twiddle hex to sim working directory (for $readmemh)
file copy -force ../rtl/twiddle_init.hex twiddle_init.hex

# Start simulation (use voptargs for signal visibility instead of deprecated -novopt)
vsim -t 1ps -voptargs="+acc" work.fft_1024_tb

# Add key signals to waveform
add wave -noupdate -divider "Clock & Reset"
add wave -noupdate /fft_1024_tb/clk
add wave -noupdate /fft_1024_tb/rst_n

add wave -noupdate -divider "AXI-Stream Input"
add wave -noupdate -radix hex /fft_1024_tb/s_axis_tdata
add wave -noupdate /fft_1024_tb/s_axis_tvalid
add wave -noupdate /fft_1024_tb/s_axis_tready
add wave -noupdate /fft_1024_tb/s_axis_tlast

add wave -noupdate -divider "AXI-Stream Output"
add wave -noupdate -radix hex /fft_1024_tb/m_axis_tdata
add wave -noupdate /fft_1024_tb/m_axis_tvalid
add wave -noupdate /fft_1024_tb/m_axis_tready
add wave -noupdate /fft_1024_tb/m_axis_tlast

add wave -noupdate -divider "FSM"
add wave -noupdate /fft_1024_tb/u_dut/state
add wave -noupdate /fft_1024_tb/u_dut/phase
add wave -noupdate -radix unsigned /fft_1024_tb/u_dut/stage_cnt
add wave -noupdate -radix unsigned /fft_1024_tb/u_dut/bfly_cnt
add wave -noupdate /fft_1024_tb/u_dut/compute_done

add wave -noupdate -divider "Butterfly"
add wave -noupdate /fft_1024_tb/u_dut/bfly_en
add wave -noupdate /fft_1024_tb/u_dut/bfly_out_valid
add wave -noupdate -radix decimal /fft_1024_tb/u_dut/bfly_out_ar
add wave -noupdate -radix decimal /fft_1024_tb/u_dut/bfly_out_ai
add wave -noupdate -radix decimal /fft_1024_tb/u_dut/bfly_out_br
add wave -noupdate -radix decimal /fft_1024_tb/u_dut/bfly_out_bi

add wave -noupdate -divider "RAM Port A"
add wave -noupdate -radix unsigned /fft_1024_tb/u_dut/ram_addr_a
add wave -noupdate /fft_1024_tb/u_dut/ram_we_a
add wave -noupdate -radix hex /fft_1024_tb/u_dut/ram_rdata_a

add wave -noupdate -divider "Output Pipeline"
add wave -noupdate -radix decimal /fft_1024_tb/u_dut/out_real_d1
add wave -noupdate -radix decimal /fft_1024_tb/u_dut/out_imag_d1
add wave -noupdate /fft_1024_tb/u_dut/out_valid_d1

# Zoom to fit
WaveRestoreZoom {0 ps} {200 us}

# Run simulation
run -all
