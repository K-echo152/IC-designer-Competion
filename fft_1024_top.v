`timescale 1ns / 1ps
//============================================================================
// fft_1024_top.v - 1024-Point Radix-2 DIT FFT (Iterative, In-place)
//============================================================================
// Architecture: Single butterfly unit, 10 iterative stages
// Data width:   16-bit I/O (Q1.15), 24-bit internal (Q9.15)
// Interface:    AXI-Stream slave (input) + AXI-Stream master (output)
// Storage:      True dual-port BRAM (1024 x 48-bit)
// Twiddle:      ROM 512 x 32-bit, loaded from hex file
// Output order: Bit-reversed
// Target:       Xilinx FPGA (Vivado synthesis)
//
// COMPUTE pipeline per butterfly (6 clock cycles):
//   phase 0: Issue RAM read addresses (addr_a, addr_b) + ROM addr
//   phase 1: Wait for RAM/ROM read latency
//   phase 2: RAM/ROM data valid, enable butterfly (bfly sees en=1 next posedge)
//   phase 3: Butterfly stage 1 - multiply (en_d1 set at end)
//   phase 4: Butterfly stage 2 - add/sub + saturate (out_valid set at end)
//   phase 5: Butterfly output valid, write back to RAM, advance counter
//   Per stage: 512 butterflies * 6 cycles = 3072 cycles
//   Total compute: 10 stages * 3072 = 30720 cycles
//============================================================================

module fft_1024_top (
    input  wire        clk,
    input  wire        rst_n,

    //--- AXI-Stream Slave (Input) ---
    input  wire [31:0] s_axis_tdata,   // {imag[31:16], real[15:0]}
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    //--- AXI-Stream Master (Output) ---
    output wire [31:0] m_axis_tdata,   // {imag[31:16], real[15:0]}
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);

    //========================================================================
    // Parameters
    //========================================================================
    localparam N       = 1024;
    localparam LOG2N   = 10;
    localparam DW      = 24;   // internal data width
    localparam TW      = 16;   // twiddle factor width

    //========================================================================
    // FSM States
    //========================================================================
    localparam [2:0] S_IDLE    = 3'd0,
                     S_LOAD    = 3'd1,
                     S_COMPUTE = 3'd2,
                     S_OUTPUT  = 3'd3;

    reg [2:0] state, state_next;

    //========================================================================
    // Counters
    //========================================================================
    reg [LOG2N-1:0] load_cnt;       // 0..1023 for loading
    reg [LOG2N-1:0] out_cnt;        // 0..1023 for output
    reg [3:0]       stage_cnt;      // 0..9 for FFT stages
    reg [8:0]       bfly_cnt;       // 0..511 for butterflies per stage
    reg [2:0]       phase;          // 0..4 sub-phases per butterfly

    //========================================================================
    // Dual-Port RAM: 1024 x 48 bits (24-bit real + 24-bit imag)
    //========================================================================
    (* ram_style = "block" *) reg [2*DW-1:0] data_ram [0:N-1];

    // Port A
    reg  [LOG2N-1:0] ram_addr_a;
    reg  [2*DW-1:0]  ram_wdata_a;
    reg              ram_we_a;
    reg  [2*DW-1:0]  ram_rdata_a;

    // Port B
    reg  [LOG2N-1:0] ram_addr_b;
    reg  [2*DW-1:0]  ram_wdata_b;
    reg              ram_we_b;
    reg  [2*DW-1:0]  ram_rdata_b;

    // Dual-port RAM: read-first mode
    always @(posedge clk) begin
        if (ram_we_a)
            data_ram[ram_addr_a] <= ram_wdata_a;
        ram_rdata_a <= data_ram[ram_addr_a];
    end

    always @(posedge clk) begin
        if (ram_we_b)
            data_ram[ram_addr_b] <= ram_wdata_b;
        ram_rdata_b <= data_ram[ram_addr_b];
    end

    //========================================================================
    // Twiddle Factor ROM
    //========================================================================
    reg  [8:0]  tw_addr;
    wire [31:0] tw_dout;

    twiddle_rom u_twiddle_rom (
        .clk  (clk),
        .addr (tw_addr),
        .dout (tw_dout)
    );

    wire signed [TW-1:0] tw_real = tw_dout[31:16]; // cos
    wire signed [TW-1:0] tw_imag = tw_dout[15:0];  // -sin

    //========================================================================
    // Butterfly Unit
    //========================================================================
    reg              bfly_en;
    wire signed [DW-1:0] bfly_out_ar, bfly_out_ai;
    wire signed [DW-1:0] bfly_out_br, bfly_out_bi;
    wire             bfly_out_valid;

    butterfly u_butterfly (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (bfly_en),
        .ar       (ram_rdata_a[2*DW-1:DW]),
        .ai       (ram_rdata_a[DW-1:0]),
        .br       (ram_rdata_b[2*DW-1:DW]),
        .bi       (ram_rdata_b[DW-1:0]),
        .wr       (tw_real),
        .wi       (tw_imag),
        .out_ar   (bfly_out_ar),
        .out_ai   (bfly_out_ai),
        .out_br   (bfly_out_br),
        .out_bi   (bfly_out_bi),
        .out_valid(bfly_out_valid)
    );

    //========================================================================
    // Address generation for butterfly operations
    //========================================================================
    // For stage s, butterfly index j (0..511):
    //   half_group = 1 << s
    //   group_size = 1 << (s+1)
    //   pair_idx   = j & (half_group - 1)
    //   group_idx  = j >> s
    //   addr_a     = group_idx * group_size + pair_idx
    //   addr_b     = addr_a + half_group
    //   tw_addr    = pair_idx << (9 - s)

    wire [LOG2N-1:0] half_group = (10'd1 << stage_cnt);
    wire [LOG2N-1:0] group_size = (10'd1 << (stage_cnt + 4'd1));

    wire [8:0] pair_idx     = bfly_cnt & (half_group[8:0] - 9'd1);
    wire [8:0] group_idx_val = bfly_cnt >> stage_cnt;

    wire [LOG2N-1:0] addr_a_calc = (group_idx_val * group_size) + {1'b0, pair_idx};
    wire [LOG2N-1:0] addr_b_calc = addr_a_calc + half_group;
    wire [8:0]       tw_addr_calc = pair_idx << (4'd9 - stage_cnt[3:0]);

    //========================================================================
    // Write-back address registers (latch at phase 0, use at phase 3)
    //========================================================================
    reg [LOG2N-1:0] wb_addr_a, wb_addr_b;

    //========================================================================
    // Bit-reversal function for output addressing
    //========================================================================
    function [LOG2N-1:0] bit_reverse;
        input [LOG2N-1:0] addr;
        integer i;
        begin
            for (i = 0; i < LOG2N; i = i + 1)
                bit_reverse[i] = addr[LOG2N-1-i];
        end
    endfunction

    //========================================================================
    // Input data sign extension: 16-bit -> 24-bit
    //========================================================================
    wire signed [DW-1:0] in_real_ext = {{(DW-16){s_axis_tdata[15]}},  s_axis_tdata[15:0]};
    wire signed [DW-1:0] in_imag_ext = {{(DW-16){s_axis_tdata[31]}}, s_axis_tdata[31:16]};

    //========================================================================
    // Output data: 24-bit -> 16-bit saturation
    //========================================================================
    function signed [15:0] sat_24to16;
        input signed [23:0] val;
        begin
            if (val > 24'sd32767)
                sat_24to16 = 16'sd32767;
            else if (val < -24'sd32768)
                sat_24to16 = -16'sd32768;
            else
                sat_24to16 = val[15:0];
        end
    endfunction

    wire signed [DW-1:0] out_real_24 = ram_rdata_a[2*DW-1:DW];
    wire signed [DW-1:0] out_imag_24 = ram_rdata_a[DW-1:0];
    wire signed [15:0]   out_real_16 = sat_24to16(out_real_24);
    wire signed [15:0]   out_imag_16 = sat_24to16(out_imag_24);

    //========================================================================
    // Output pipeline registers (1-cycle RAM read latency)
    //========================================================================
    reg        out_valid_d1;
    reg        out_last_d1;
    reg [15:0] out_real_d1, out_imag_d1;
    reg        out_reading;        // read address was issued this cycle
    reg        out_data_rdy;       // RAM data is valid (1 cycle after out_reading)
    reg [LOG2N-1:0] out_cnt_d1;   // delayed count for tlast
    reg [LOG2N-1:0] out_cnt_d2;   // double-delayed for data valid stage

    // out_reading and out_cnt_d1 are managed in the main FSM always block.
    // This block delays out_reading by 1 cycle to align with RAM read data.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid_d1 <= 1'b0;
            out_last_d1  <= 1'b0;
            out_real_d1  <= 16'd0;
            out_imag_d1  <= 16'd0;
            out_data_rdy <= 1'b0;
            out_cnt_d2   <= 0;
        end else begin
            out_data_rdy <= out_reading;
            out_cnt_d2   <= out_cnt_d1;

            if (state == S_IDLE) begin
                // Clear output pipeline when idle
                out_valid_d1 <= 1'b0;
                out_data_rdy <= 1'b0;
            end else if (out_data_rdy) begin
                // RAM data from read issued 2 cycles ago is now valid
                out_valid_d1 <= 1'b1;
                out_real_d1  <= out_real_16;
                out_imag_d1  <= out_imag_16;
                out_last_d1  <= (out_cnt_d2 == N-1);
            end else if (m_axis_tready) begin
                out_valid_d1 <= 1'b0;
            end
        end
    end

    //========================================================================
    // Compute-done flag
    //========================================================================
    reg compute_done;

    //========================================================================
    // FSM: State Register
    //========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= state_next;
    end

    //========================================================================
    // FSM: Next State Logic
    //========================================================================
    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE: begin
                if (s_axis_tvalid)
                    state_next = S_LOAD;
            end
            S_LOAD: begin
                if (s_axis_tvalid && (load_cnt == N-1))
                    state_next = S_COMPUTE;
            end
            S_COMPUTE: begin
                if (compute_done)
                    state_next = S_OUTPUT;
            end
            S_OUTPUT: begin
                if (out_valid_d1 && out_last_d1 && m_axis_tready)
                    state_next = S_IDLE;
            end
            default: state_next = S_IDLE;
        endcase
    end

    //========================================================================
    // FSM: Datapath Control
    //========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_cnt     <= 0;
            out_cnt      <= 0;
            stage_cnt    <= 0;
            bfly_cnt     <= 0;
            phase        <= 0;
            bfly_en      <= 1'b0;
            ram_we_a     <= 1'b0;
            ram_we_b     <= 1'b0;
            ram_addr_a   <= 0;
            ram_addr_b   <= 0;
            ram_wdata_a  <= 0;
            ram_wdata_b  <= 0;
            tw_addr      <= 0;
            wb_addr_a    <= 0;
            wb_addr_b    <= 0;
            compute_done <= 1'b0;
            out_reading  <= 1'b0;
            out_cnt_d1   <= 0;
        end else begin
            // Defaults each cycle
            ram_we_a     <= 1'b0;
            ram_we_b     <= 1'b0;
            bfly_en      <= 1'b0;
            compute_done <= 1'b0;

            // out_reading auto-clear: set for one cycle only
            if (out_reading)
                out_reading <= 1'b0;

            case (state)
                //------------------------------------------------------------
                // IDLE
                //------------------------------------------------------------
                S_IDLE: begin
                    load_cnt  <= 0;
                    out_cnt   <= 0;
                    stage_cnt <= 0;
                    bfly_cnt  <= 0;
                    phase     <= 0;
                end

                //------------------------------------------------------------
                // LOAD: write input data to RAM via port A
                //------------------------------------------------------------
                S_LOAD: begin
                    if (s_axis_tvalid) begin
                        ram_addr_a  <= load_cnt;
                        ram_wdata_a <= {in_real_ext, in_imag_ext};
                        ram_we_a    <= 1'b1;
                        load_cnt    <= load_cnt + 1;
                    end
                end

                //------------------------------------------------------------
                // COMPUTE: 4-phase per butterfly
                //------------------------------------------------------------
                S_COMPUTE: begin
                    case (phase)
                        3'd0: begin
                            // Phase 0: Issue read addresses to RAM and ROM
                            ram_addr_a <= addr_a_calc;
                            ram_addr_b <= addr_b_calc;
                            tw_addr    <= tw_addr_calc;
                            wb_addr_a  <= addr_a_calc;
                            wb_addr_b  <= addr_b_calc;
                            phase      <= 3'd1;
                        end

                        3'd1: begin
                            // Phase 1: Wait for RAM/ROM read latency
                            // Data will be valid at end of this cycle
                            phase <= 3'd2;
                        end

                        3'd2: begin
                            // Phase 2: RAM/ROM data valid now,
                            // enable butterfly to latch and start multiply
                            // (butterfly sees en=1 at next posedge = phase 3)
                            bfly_en <= 1'b1;
                            phase   <= 3'd3;
                        end

                        3'd3: begin
                            // Phase 3: Butterfly stage 1 - multiply
                            // en_d1 will be set at end of this cycle
                            phase <= 3'd4;
                        end

                        3'd4: begin
                            // Phase 4: Butterfly stage 2 - add/sub + saturate
                            // out_valid and out_ar/ai/br/bi set at end of this cycle
                            phase <= 3'd5;
                        end

                        3'd5: begin
                            // Phase 5: Butterfly output valid, write back
                            ram_we_a    <= 1'b1;
                            ram_addr_a  <= wb_addr_a;
                            ram_wdata_a <= {bfly_out_ar, bfly_out_ai};
                            ram_we_b    <= 1'b1;
                            ram_addr_b  <= wb_addr_b;
                            ram_wdata_b <= {bfly_out_br, bfly_out_bi};

                            // Advance to next butterfly
                            if (bfly_cnt == 9'd511) begin
                                bfly_cnt <= 0;
                                if (stage_cnt == LOG2N - 1) begin
                                    compute_done <= 1'b1;
                                    phase <= 3'd0;
                                end else begin
                                    stage_cnt <= stage_cnt + 1;
                                    phase     <= 3'd0;
                                end
                            end else begin
                                bfly_cnt <= bfly_cnt + 1;
                                phase    <= 3'd0;
                            end
                        end

                        default: phase <= 3'd0;
                    endcase
                end

                //------------------------------------------------------------
                // OUTPUT: Read bit-reversed, send via AXI-Stream
                //------------------------------------------------------------
                S_OUTPUT: begin
                    if (!out_reading && !out_data_rdy && (!out_valid_d1 || m_axis_tready)) begin
                        if (out_cnt < N) begin
                            ram_addr_a  <= bit_reverse(out_cnt);
                            out_cnt_d1  <= out_cnt;
                            out_cnt     <= out_cnt + 1;
                            out_reading <= 1'b1;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    //========================================================================
    // AXI-Stream Assignments
    //========================================================================
    assign s_axis_tready = (state == S_LOAD);
    assign m_axis_tdata  = {out_imag_d1, out_real_d1};
    assign m_axis_tvalid = out_valid_d1;
    assign m_axis_tlast  = out_valid_d1 && out_last_d1;

endmodule
