`timescale 1ns / 1ps               // 时间单位：1ns，精度：1ps
//============================================================================
// butterfly.v - Radix-2 Butterfly Unit for FFT
//============================================================================
// 功能说明：
//   实现FFT中的基2蝶形运算
//   A' = A + W*B
//   B' = A - W*B
// 其中 W 是旋转因子(复数)，A/B 是输入复数数据
//
// 流水线结构：2级
//   第1级 (T+1)：复数乘法 W*B
//   第2级 (T+2)：加法/减法运算 + 饱和截位
//
// 数据格式：
//   A, B: 24位有符号数 实部+虚部 (Q9.15格式)
//   W:    16位有符号数 实部+虚部 (Q1.15格式)
//   输出: 24位有符号数 实部+虚部 (Q9.15格式)
//============================================================================

// 蝶形运算模块定义
module butterfly (
    input  wire        clk,         // 时钟信号
    input  wire        rst_n,       // 复位信号，低电平有效
    input  wire        en,          // 流水线使能信号，为1时运算有效
 
    // 输入复数数据 A、B，各24位（实部+虚部）
    input  wire signed [23:0] ar,   // 输入A的实部
    input  wire signed [23:0] ai,   // 输入A的虚部
    input  wire signed [23:0] br,   // 输入B的实部
    input  wire signed [23:0] bi,   // 输入B的虚部

    // 旋转因子 W（复数），各16位
    input  wire signed [15:0] wr,   // 旋转因子实部（cos值）
    input  wire signed [15:0] wi,   // 旋转因子虚部（-sin值）

    // 输出结果 A'、B'，各24位（实部+虚部）
    output reg  signed [23:0] out_ar,  // 输出A'的实部
    output reg  signed [23:0] out_ai,  // 输出A'的虚部
    output reg  signed [23:0] out_br,  // 输出B'的实部
    output reg  signed [23:0] out_bi,  // 输出B'的虚部
    output reg                out_valid // 输出有效标志位
); 

    //------------------------------------------------------------------------
    // 第1级流水线：复数乘法 W * B
    // 公式：
    // 实部 pr = wr*br - wi*bi
    // 虚部 pi = wr*bi + wi*br
    // 16bit × 24bit = 40bit 有符号乘积
    //------------------------------------------------------------------------
    // 定义乘法结果寄存器，40位存储乘法输出
    reg signed [39:0] mul_wr_br, mul_wi_bi, mul_wr_bi, mul_wi_br;
    reg signed [23:0] ar_d1, ai_d1;    // 将A数据延迟1拍，与乘法结果对齐
    reg               en_d1;           // 使能信号延迟1拍

    // 第1级时序逻辑：乘法运算 + 数据延迟
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin              // 复位状态
            mul_wr_br <= 40'd0;
            mul_wi_bi <= 40'd0;
            mul_wr_bi <= 40'd0;
            mul_wi_br <= 40'd0;
            ar_d1     <= 24'd0;
            ai_d1     <= 24'd0;
            en_d1     <= 1'b0;
        end else if (en) begin         // 使能有效，执行乘法和寄存
            // 4个乘法器，会被FPGA综合为DSP48硬件单元
            mul_wr_br <= wr * br;      // 旋转因子实部 × B实部
            mul_wi_bi <= wi * bi;      // 旋转因子虚部 × B虚部
            mul_wr_bi <= wr * bi;      // 旋转因子实部 × B虚部
            mul_wi_br <= wi * br;      // 旋转因子虚部 × B实部
            
            ar_d1     <= ar;           // A实部延迟1拍
            ai_d1     <= ai;           // A虚部延迟1拍
            en_d1     <= 1'b1;         // 使能信号延迟1拍
        end else begin                 // 使能无效
            en_d1     <= 1'b0;         // 级使能拉低
        end
    end

    //------------------------------------------------------------------------
    // 第1级组合逻辑：从40位乘法结果中截位得到24位结果
    // 从 Q10.30 格式提取为 Q9.15 格式
    // 取 [38:15] 共24位作为有效位，加 rounding bit 减少截断误差
    //------------------------------------------------------------------------
    wire signed [23:0] wr_br_round = mul_wr_br[38:15] + mul_wr_br[14];
    wire signed [23:0] wi_bi_round = mul_wi_bi[38:15] + mul_wi_bi[14];
    wire signed [23:0] wr_bi_round = mul_wr_bi[38:15] + mul_wr_bi[14];
    wire signed [23:0] wi_br_round = mul_wi_br[38:15] + mul_wi_br[14];
    wire signed [23:0] pr = wr_br_round - wi_bi_round; // 乘法后实部
    wire signed [23:0] pi = wr_bi_round + wi_br_round; // 乘法后虚部

    //------------------------------------------------------------------------
    // 第2级组合逻辑：蝶形加/减法运算
    // A' = A + W*B
    // B' = A - W*B
    // 扩展1位符号位，防止溢出
    //------------------------------------------------------------------------
    wire signed [24:0] sum_r = {ar_d1[23], ar_d1} + {pr[23], pr}; // A'实部 = A延迟 + 乘法实部
    wire signed [24:0] sum_i = {ai_d1[23], ai_d1} + {pi[23], pi}; // A'虚部 = A延迟 + 乘法虚部
    wire signed [24:0] dif_r = {ar_d1[23], ar_d1} - {pr[23], pr}; // B'实部 = A延迟 - 乘法实部
    wire signed [24:0] dif_i = {ai_d1[23], ai_d1} - {pi[23], pi}; // B'虚部 = A延迟 - 乘法虚部

    //------------------------------------------------------------------------
    // 饱和截位函数：将25位数据限制在24位有符号数范围内
    // 防止数据溢出导致波形失真
    //------------------------------------------------------------------------
    function signed [23:0] saturate;
        input signed [24:0] val;      // 输入25位待截位数据
        begin
            if (val > 25'sd8388607)        // 大于2^23-1，上限饱和
                saturate = 24'sd8388607;
            else if (val < -25'sd8388608)  // 小于-2^23，下限饱和
                saturate = -24'sd8388608;
            else                          // 正常范围，直接取低24位
                saturate = val[23:0];
        end
    endfunction

    //------------------------------------------------------------------------
    // 第2级时序逻辑：饱和输出 + 结果寄存
    //------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin              // 复位状态
            out_ar    <= 24'd0;
            out_ai    <= 24'd0;
            out_br    <= 24'd0;
            out_bi    <= 24'd0;
            out_valid <= 1'b0;
        end else if (en_d1) begin      // 第1级运算完成，执行第2级输出
            out_ar    <= saturate(sum_r);  // 输出A'实部（饱和后）
            out_ai    <= saturate(sum_i);  // 输出A'虚部（饱和后）
            out_br    <= saturate(dif_r);  // 输出B'实部（饱和后）
            out_bi    <= saturate(dif_i);  // 输出B'虚部（饱和后）
            out_valid <= 1'b1;             // 输出有效标志置1
        end else begin                 // 无有效运算
            out_valid <= 1'b0;         // 输出无效
        end
    end

endmodule