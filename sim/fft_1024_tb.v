//============================================================================
// fft_1024_tb.v - Testbench for 1024-Point FFT
//============================================================================
// Tests:
//   1. Impulse input: x[0]=1, rest=0 -> all outputs should be equal
//   2. Random complex input: verify completion without hangs
// Simulator: Vivado xsim compatible
//============================================================================

`timescale 1ns / 1ps

module fft_1024_tb;

    //========================================================================
    // Parameters
    //========================================================================
    localparam CLK_PERIOD = 10;   // 100 MHz
    localparam N = 1024;

    //========================================================================
    // DUT Signals
    //========================================================================
    reg         clk;
    reg         rst_n;

    // AXI-Stream Slave (input to DUT)
    reg  [31:0] s_axis_tdata;
    reg         s_axis_tvalid;
    wire        s_axis_tready;
    reg         s_axis_tlast;

    // AXI-Stream Master (output from DUT)
    wire [31:0] m_axis_tdata;
    wire        m_axis_tvalid;
    reg         m_axis_tready;
    wire        m_axis_tlast;

    //========================================================================
    // DUT Instantiation
    //========================================================================
    fft_1024_top u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast)
    );

    //========================================================================
    // Clock Generation
    //========================================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    //========================================================================
    // Test Data Storage
    //========================================================================
    reg signed [15:0] in_real  [0:N-1];
    reg signed [15:0] in_imag  [0:N-1];
    reg signed [15:0] out_real [0:N-1];
    reg signed [15:0] out_imag [0:N-1];
    integer out_idx;
    integer i;
    integer test_num;

    //========================================================================
    // Waveform Dump
    //========================================================================
    initial begin
        $dumpfile("fft_1024_tb.vcd");
        $dumpvars(0, fft_1024_tb);
    end

    //========================================================================
    // Task: Send N data points via AXI-Stream
    //========================================================================
    task send_data;
        integer k;
        begin
            @(posedge clk);
            s_axis_tvalid <= 1'b1;

            for (k = 0; k < N; k = k + 1) begin
                s_axis_tdata <= {in_imag[k], in_real[k]};
                s_axis_tlast <= (k == N-1) ? 1'b1 : 1'b0;

                @(posedge clk);
                while (!s_axis_tready) @(posedge clk);
            end

            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
            s_axis_tdata  <= 32'd0;
        end
    endtask

    //========================================================================
    // Task: Receive N data points via AXI-Stream
    //========================================================================
    task receive_data;
        begin
            out_idx = 0;
            m_axis_tready <= 1'b1;

            while (out_idx < N) begin
                @(posedge clk);
                if (m_axis_tvalid && m_axis_tready) begin
                    out_real[out_idx] = m_axis_tdata[15:0];
                    out_imag[out_idx] = m_axis_tdata[31:16];
                    out_idx = out_idx + 1;
                end
            end

            m_axis_tready <= 1'b0;
        end
    endtask

    //========================================================================
    // Task: Print first 16 output points
    //========================================================================
    task print_outputs;
        input integer count;
        integer k;
        begin
            $display("--- Output (first %0d points) ---", count);
            for (k = 0; k < count && k < N; k = k + 1) begin
                $display("  X[%4d] = %6d + j*%6d", k, out_real[k], out_imag[k]);
            end
            $display("---");
        end
    endtask

    //========================================================================
    // Main Test Sequence
    //========================================================================
    initial begin
        // Initialize
        rst_n         = 1'b0;
        s_axis_tdata  = 32'd0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b0;

        // Reset
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        //================================================================
        // Test 1: Impulse - x[0] = 16384 (0.5 in Q1.15), rest = 0
        // Expected: All FFT bins should have equal magnitude
        //================================================================
        test_num = 1;
        $display("\n========================================");
        $display("Test %0d: Impulse Input", test_num);
        $display("========================================");

        for (i = 0; i < N; i = i + 1) begin
            in_real[i] = 16'd0;
            in_imag[i] = 16'd0;
        end
        in_real[0] = 16'sd16384;  // 0.5 in Q1.15

        fork
            send_data;
            receive_data;
        join

        print_outputs(16);

        // Verify: all output should be (16384, 0)
        begin : impulse_check
            integer err_count;
            err_count = 0;
            for (i = 0; i < N; i = i + 1) begin
                if (out_real[i] != 16'sd16384 || out_imag[i] != 16'sd0) begin
                    if (err_count < 5)
                        $display("  MISMATCH X[%0d] = (%0d, %0d), expected (16384, 0)",
                            i, out_real[i], out_imag[i]);
                    err_count = err_count + 1;
                end
            end
            if (err_count == 0)
                $display("Test %0d: PASS - all %0d bins correct", test_num, N);
            else
                $display("Test %0d: FAIL - %0d mismatches", test_num, err_count);
        end
        repeat (10) @(posedge clk);

        //================================================================
        // Test 2: Random complex data
        //================================================================
        test_num = 2;
        $display("\n========================================");
        $display("Test %0d: Random Input", test_num);
        $display("========================================");

        for (i = 0; i < N; i = i + 1) begin
            in_real[i] = $random % 4096;   // small random values to avoid overflow
            in_imag[i] = $random % 4096;
        end

        fork
            send_data;
            receive_data;
        join

        print_outputs(16);
        $display("Test %0d: Random test completed", test_num);

        //================================================================
        // Test 3: DC signal (all ones) - should concentrate at bin 0
        //================================================================
        test_num = 3;
        $display("\n========================================");
        $display("Test %0d: DC Input (constant value)", test_num);
        $display("========================================");

        for (i = 0; i < N; i = i + 1) begin
            in_real[i] = 16'sd100;
            in_imag[i] = 16'sd0;
        end

        fork
            send_data;
            receive_data;
        join

        print_outputs(16);

        // Verify: X[0] should be (32767, 0) (saturated), others near 0
        begin : dc_check
            integer err_count;
            err_count = 0;
            if (out_real[0] != 16'sd32767 || out_imag[0] != 16'sd0) begin
                $display("  DC MISMATCH X[0] = (%0d, %0d), expected (32767, 0)",
                    out_real[0], out_imag[0]);
                err_count = err_count + 1;
            end
            for (i = 1; i < N; i = i + 1) begin
                if (out_real[i] > 16'sd200 || out_real[i] < -16'sd200 ||
                    out_imag[i] > 16'sd200 || out_imag[i] < -16'sd200) begin
                    if (err_count < 5)
                        $display("  DC MISMATCH X[%0d] = (%0d, %0d), expected ~(0, 0)",
                            i, out_real[i], out_imag[i]);
                    err_count = err_count + 1;
                end
            end
            if (err_count == 0)
                $display("Test %0d: PASS - DC test correct", test_num);
            else
                $display("Test %0d: FAIL - %0d mismatches", test_num, err_count);
        end

        //================================================================
        // Done
        //================================================================
        $display("\n========================================");
        $display("All tests completed!");
        $display("========================================\n");
        repeat (20) @(posedge clk);
        $finish;
    end

    //========================================================================
    // Timeout watchdog
    //========================================================================
    initial begin
        #(CLK_PERIOD * 700000);  // 7ms timeout
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule
