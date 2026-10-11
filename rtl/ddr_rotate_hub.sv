// DDR3 rotation hub for the GX7 series cores (Battlantis, Rack 'Em Up / The Hustler, Blades of Steel).
//
// What it does
//   1. Wraps the framework's screen_rotate (the HDMI rotation framebuffer in DDR3), as rtl/screen_rotate_ex.v (identical to the original unless
//      raw_fb is set, see below), and puts a write queue in front of its DDR3 port. screen_rotate ignores DDRAM_BUSY completely (one fire-and-forget write per pixel), so it
//      could silently lose pixels as soon as anything else uses the port. The queue (fifo A) makes it immune.
//   2. Adds a CRT rotation path for the analog output: every native pixel is ALSO written, already rotated, into its own pair of
//      DDR3 buffers (fifo B, 0x26000000 by default). A line reader fetches the rotated picture back, one source row per
//      output line, scales it with a nearest neighbour accumulator and drives crt_r/g/b/hs/vs/de.
//
// Why this replaced the old on chip rotation buffer (rtl/direct_video_rotate.v, 134 M10K blocks): the DDR3 port has about
// 380 MB/s and this needs about 70 MB/s, and the line buffers below are built from MLABs (logic cells), because the cores run
// at 553 of 553 M10K blocks.
//
// Independence of the two screens
//   * CRT Flip (crt_flip), size, enable (crt_en) are separate from the HDMI orientation and flip. The CRT buffers are written whatever the
//     HDMI mode is.
//   * While crt_en is set and the HDMI picture is raw (no_rotate), screen_rotate_ex writes the raw HDMI picture into its framebuffer too (raw_fb), so the
//     HDMI scaler stops using the core's VGA pins, which now carry the rotated CRT picture. Without crt_en nothing changes from the original behaviour.
//   * The analog picture enable (crt_de) is ALWAYS the native one (delayed). The MiSTer OSD sizes itself from the width of the enable, so the OSD
//     stays exactly the same size whether the CRT picture is raw or rotated.
//
// Timing
//   The CRT output keeps the NATIVE sync (crt_hs and crt_vs are VGA_HS and VGA_VS, delayed to line up with the picture), so the
//   analog timing stays exactly the proven raw 15 kHz timing. Only the picture content changes. Because the output frame is the
//   native frame, writer and reader are phase locked and two buffers are enough (no tearing, no genlock clock needed):
//   at every native VS edge the buffer just written becomes the buffer the reader uses for the whole next frame, and the
//   writer moves to the other one. Cost: one frame (16.9 ms) of latency on the CRT picture.
//
// Picture layouts (written by this module, read back by this module). Source pixel (x, y) of the native active window (x 0..255 across, y 0..223 down):
//   rotated (crt_en):     clockwise  row = x,       col = 223 - y     counter clockwise (crt_flip)  row = 255 - x, col = y
//                         256 rows of 224 pixels = 112 words, read back scaled (crt_size / auto)
//   raw (crt_en = 0, crt_flip = 1, the unrotated picture flipped by 180 degrees): row = 223 - y, col = 255 - x
//                         224 rows of 256 pixels = 128 words, read back 1:1 exactly where the native picture is
//   one word = two 32 bit pixels (low half = even column), pixel = {8'd0,B,G,R}.
//   With both crt_en and crt_flip low the buffers are not used at all: the analog pins carry the raw raster straight through (delayed two pixel clocks).
//
// The picture is SRC_W x SRC_H (224 x 256) before scaling. crt_size selects d = 14 + crt_size (d/32 of full size, 14..29):
// out_w = 7 * d, out_h = 8 * d, i.e. 98x112 up to 203x232 (the old design's ceiling for a 264 line frame).
// crt_hpos / crt_vpos (16 = centred) move the picture one pixel / one line per step.
// CRT Flip is the only rotation control: in the rotated picture it picks counter clockwise instead of clockwise, in the raw picture it turns it by 180 degrees.
module ddr_rotate_hub #(
    parameter [6:0] CRT_MEM_BASE = 7'b0010011    // CRT buffers at 0x26000000 (screen_rotate uses 0x24000000, 3 x 8 MB)
) (
    input         CLK_VIDEO,
    input         CE_PIXEL,

    // native raster, from arcade_video (the same signals screen_rotate gets)
    input   [7:0] VGA_R,
    input   [7:0] VGA_G,
    input   [7:0] VGA_B,
    input         VGA_HS,
    input         VGA_VS,
    input         VGA_DE,

    input         rotate_ccw,
    input         no_rotate,
    input         flip,
    output        video_rotated,

    output        FB_EN,
    output  [4:0] FB_FORMAT,
    output [11:0] FB_WIDTH,
    output [11:0] FB_HEIGHT,
    output [31:0] FB_BASE,
    output [13:0] FB_STRIDE,
    input         FB_VBL,
    input         FB_LL,

    output        DDRAM_CLK,
    input         DDRAM_BUSY,
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    input  [63:0] DDRAM_DOUT,
    input         DDRAM_DOUT_READY,
    output        DDRAM_RD,
    output [63:0] DDRAM_DIN,
    output  [7:0] DDRAM_BE,
    output        DDRAM_WE,

    // CRT rotation path
    input         crt_en,        // OSD: CRT orientation Horizontal (rotated). Independent of the HDMI orientation.
    input         crt_flip,      // OSD: CRT Flip (180 degrees): counter clockwise when rotated, upside down when raw (independent of the HDMI flip)
    input         crt_size_auto, // OSD: pick the largest picture that fits the frame (vertical total minus 32 lines)
    input   [3:0] crt_size,
    input   [4:0] crt_hpos,
    input   [4:0] crt_vpos,
    output  [7:0] crt_r,
    output  [7:0] crt_g,
    output  [7:0] crt_b,
    output        crt_hs,
    output        crt_vs,
    output        crt_de,
    output        crt_ready,     // a complete frame is in the buffer and the rotated picture is being shown
    output  [1:0] crt_status     // sticky overflow flags {fifo B, fifo A}, for debug overlays
);


assign DDRAM_CLK = CLK_VIDEO;

// ====================================================================================================================
// screen_rotate (HDMI path), unchanged
// ====================================================================================================================
reg         crt_en_s1 = 0, crt_en_s2 = 0, crt_fl_s1 = 0, crt_fl_s2 = 0;   // OSD status synchronised (it comes from another clock domain)
wire        sr_clk;
wire  [7:0] sr_burst;
wire [28:0] sr_addr;
wire [63:0] sr_din;
wire  [7:0] sr_be;
wire        sr_we, sr_rd;

screen_rotate_ex screen_rotate (
    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R),
    .VGA_G(VGA_G),
    .VGA_B(VGA_B),
    .VGA_HS(VGA_HS),
    .VGA_VS(VGA_VS),
    .VGA_DE(VGA_DE),
    .rotate_ccw(rotate_ccw),
    .no_rotate(no_rotate),
    .raw_fb((crt_en_s2 | crt_fl_s2) & no_rotate),   // the pins carry the CRT picture whenever the buffers are used, so HDMI raw goes through its own framebuffer
    .flip(flip),
    .video_rotated(video_rotated),
    .FB_EN(FB_EN),
    .FB_FORMAT(FB_FORMAT),
    .FB_WIDTH(FB_WIDTH),
    .FB_HEIGHT(FB_HEIGHT),
    .FB_BASE(FB_BASE),
    .FB_STRIDE(FB_STRIDE),
    .FB_VBL(FB_VBL),
    .FB_LL(FB_LL),
    .DDRAM_CLK(sr_clk),
    .DDRAM_BUSY(1'b0),
    .DDRAM_BURSTCNT(sr_burst),
    .DDRAM_ADDR(sr_addr),
    .DDRAM_DIN(sr_din),
    .DDRAM_BE(sr_be),
    .DDRAM_WE(sr_we),
    .DDRAM_RD(sr_rd)
);

// ====================================================================================================================
// Write queues. Entry = {high word flag, 29 bit word address, 32 bit pixel}. Depth 64 each, MLAB based.
// ====================================================================================================================
(* ramstyle = "MLAB, no_rw_check" *) reg [61:0] fa_mem [0:63];
(* ramstyle = "MLAB, no_rw_check" *) reg [61:0] fb_mem [0:63];
reg   [6:0] fa_wp = 0, fa_rp = 0, fb_wp = 0, fb_rp = 0;
reg         fa_ovf = 0, fb_ovf = 0;
wire        fa_empty = (fa_wp == fa_rp);
wire        fb_empty = (fb_wp == fb_rp);
wire        fa_full  = (fa_wp[5:0] == fa_rp[5:0]) && (fa_wp[6] != fa_rp[6]);
wire        fb_full  = (fb_wp[5:0] == fb_rp[5:0]) && (fb_wp[6] != fb_rp[6]);
wire [61:0] fa_q = fa_mem[fa_rp[5:0]];
wire [61:0] fb_q = fb_mem[fb_rp[5:0]];

reg         fb_push = 0;
reg  [61:0] fb_din  = 0;

always @(posedge CLK_VIDEO) begin
    if (sr_we) begin
        if (!fa_full) begin
            fa_mem[fa_wp[5:0]] <= {sr_be[7], sr_addr, sr_din[31:0]};
            fa_wp <= fa_wp + 1'd1;
        end else fa_ovf <= 1'b1;
    end

    if (fb_push) begin
        if (!fb_full) begin
            fb_mem[fb_wp[5:0]] <= fb_din;
            fb_wp <= fb_wp + 1'd1;
        end else fb_ovf <= 1'b1;
    end
end

assign crt_status = {fb_ovf, fa_ovf};

// ====================================================================================================================
// CRT write path: native pixel -> rotated address -> fifo B
// ====================================================================================================================
reg        w_old_vs = 0, w_old_de = 0;
reg  [8:0] w_x = 0, w_y = 9'h1FF;
reg        wbuf = 0;            // buffer being written
reg        rbuf = 0;            // buffer the reader uses (the one completed by the previous frame)
reg        crt_act_frame = 0;   // the CRT buffers are used (crt_en or crt_flip), latched at the frame start
reg        wm_rot = 0, wm_flip = 0;   // layout of the frame being written (latched at the frame start)
reg        rm_rot = 0, rm_flip = 0;   // layout of the buffer the reader uses
reg        crt_ok = 0;          // the frame just completed was written completely

wire       w_vs_rise = ~w_old_vs & VGA_VS;
wire       w_de_rise = ~w_old_de & VGA_DE;
wire [8:0] w_px = w_de_rise ? 9'd0 : w_x;
wire [8:0] w_py = w_de_rise ? (w_y + 1'd1) : w_y;
// rotated layout: 256 rows x 224 columns (112 words a row); raw layout: 224 rows x 256 columns (128 words a row)
wire [7:0] wr_row = wm_flip ? (8'd255 - w_px[7:0]) : w_px[7:0];
wire [7:0] wr_col = wm_flip ? w_py[7:0] : (8'd223 - w_py[7:0]);
wire [7:0] wn_row = wm_flip ? (8'd223 - w_py[7:0]) : w_py[7:0];
wire [7:0] wn_col = wm_flip ? (8'd255 - w_px[7:0]) : w_px[7:0];
wire [7:0] w_row  = wm_rot ? wr_row : wn_row;
wire [7:0] w_col  = wm_rot ? wr_col : wn_col;
wire [14:0] w_word = wm_rot ? ({w_row, 6'd0} + {1'b0, w_row, 5'd0} + {2'b0, w_row, 4'd0} + {8'd0, w_col[7:1]})   // row * 112 + col / 2
                            : ({1'b0, w_row, 6'd0} + {1'b0, w_row, 6'd0} + {8'd0, w_col[7:1]});               // row * 128 + col / 2
wire       w_inside = (w_px < 9'd256) && (w_py < 9'd224);

always @(posedge CLK_VIDEO) begin
    fb_push <= 1'b0;
    crt_en_s1 <= crt_en;
    crt_en_s2 <= crt_en_s1;
    crt_fl_s1 <= crt_flip;
    crt_fl_s2 <= crt_fl_s1;
    if (CE_PIXEL) begin
        w_old_vs <= VGA_VS;
        w_old_de <= VGA_DE;
        if (w_vs_rise) begin
            w_y   <= 9'h1FF;
            crt_ok        <= crt_act_frame;
            crt_act_frame <= crt_en_s2 | crt_fl_s2;
            rm_rot  <= wm_rot;      // the buffer just completed was written in the layout of the frame that ended
            rm_flip <= wm_flip;
            wm_rot  <= crt_en_s2;
            wm_flip <= crt_fl_s2;
            rbuf  <= wbuf;
            wbuf  <= ~wbuf;
        end
        if (VGA_DE) begin
            w_x <= w_px + 1'd1;
            w_y <= w_py;
            if (crt_act_frame && w_inside) begin
                fb_push <= 1'b1;
                fb_din  <= {w_col[0], CRT_MEM_BASE, 6'd0, wbuf, w_word, 8'd0, VGA_B, VGA_G, VGA_R};
            end
        end
    end
end

// ====================================================================================================================
// Native raster measurement (pixel clock domain): hcol since the last HS rising edge, vline since the last VS rising edge,
// and where the native picture starts (hde0 columns after HS, lde0 lines after VS). Measured, not hardcoded, so the rotated
// picture follows the native sync whatever the CRT position options do to it.
// ====================================================================================================================
reg        m_old_hs = 0, m_old_vs = 0, m_old_de = 0;
reg  [8:0] hcol = 0, vline = 0;
reg  [8:0] hde0 = 9'd48, lde0 = 9'd36;
reg        de_first = 0;
reg        ls_ev = 0;                       // one clk pulse, a new line started (with the pixel enable)

// Frame height measured from the native vsync (lines between two VS rising edges). Automatic size: the largest picture, out_h = 8 * d lines, that
// leaves 32 lines of blanking (232 lines for the 264 line frame of the GX7 cores), limited to the table (d = 14..29).
reg  [8:0] vtot = 9'd264;
wire [9:0] auto_d_raw = {1'b0, (vtot - 9'd32)} >> 3;
wire [3:0] auto_size  = (auto_d_raw > 10'd29) ? 4'd15 : (auto_d_raw < 10'd14) ? 4'd0 : (auto_d_raw[3:0] - 4'd14);
wire [3:0] size_sel   = crt_size_auto ? auto_size : crt_size;

// scale table: d = 14 + size_sel
reg  [8:0] t_out_w, t_out_h;
reg [20:0] t_inc;
always @(*) begin
    case (size_sel)
        4'd0:  begin t_out_w = 9'd98;  t_out_h = 9'd112; t_inc = 21'd149797; end
        4'd1:  begin t_out_w = 9'd105; t_out_h = 9'd120; t_inc = 21'd139810; end
        4'd2:  begin t_out_w = 9'd112; t_out_h = 9'd128; t_inc = 21'd131072; end
        4'd3:  begin t_out_w = 9'd119; t_out_h = 9'd136; t_inc = 21'd123362; end
        4'd4:  begin t_out_w = 9'd126; t_out_h = 9'd144; t_inc = 21'd116508; end
        4'd5:  begin t_out_w = 9'd133; t_out_h = 9'd152; t_inc = 21'd110376; end
        4'd6:  begin t_out_w = 9'd140; t_out_h = 9'd160; t_inc = 21'd104858; end
        4'd7:  begin t_out_w = 9'd147; t_out_h = 9'd168; t_inc = 21'd99864;  end
        4'd8:  begin t_out_w = 9'd154; t_out_h = 9'd176; t_inc = 21'd95325;  end
        4'd9:  begin t_out_w = 9'd161; t_out_h = 9'd184; t_inc = 21'd91181;  end
        4'd10: begin t_out_w = 9'd168; t_out_h = 9'd192; t_inc = 21'd87381;  end
        4'd11: begin t_out_w = 9'd175; t_out_h = 9'd200; t_inc = 21'd83886;  end
        4'd12: begin t_out_w = 9'd182; t_out_h = 9'd208; t_inc = 21'd80660;  end
        4'd13: begin t_out_w = 9'd189; t_out_h = 9'd216; t_inc = 21'd77672;  end
        4'd14: begin t_out_w = 9'd196; t_out_h = 9'd224; t_inc = 21'd74898;  end
        default: begin t_out_w = 9'd203; t_out_h = 9'd232; t_inc = 21'd72316; end
    endcase
end

// The raw layout (CRT Flip with the CRT Orientation Vertical) is shown 1:1 at the native size, exactly where the native picture is.
wire  [8:0] out_w = rm_rot ? t_out_w : 9'd256;
wire  [8:0] out_h = rm_rot ? t_out_h : 9'd224;
wire [20:0] inc   = rm_rot ? t_inc   : 21'd65536;

// picture window (signed, in hcol / vline units). SRC_W and SRC_H are the unscaled sizes, centre of the native window = 128 / 112.
reg signed [10:0] hstart_r = 0, vstart_r = 0;
always @(posedge CLK_VIDEO) if (CE_PIXEL) begin
    hstart_r <= $signed({2'b0, hde0}) + 11'sd128 - $signed({3'b0, out_w[8:1]}) + $signed({6'b0, crt_hpos}) - 11'sd16;
    vstart_r <= $signed({2'b0, lde0}) + 11'sd112 - $signed({3'b0, out_h[8:1]}) + $signed({6'b0, crt_vpos}) - 11'sd16;
end

// line fetch request (set in the pixel domain, consumed by the fetch state machine)
reg        f_start = 0;
reg  [7:0] f_row = 0;
reg        f_buf = 0;
reg [23:0] vacc = 0;

always @(posedge CLK_VIDEO) begin
    reg [8:0]  vline_n;
    reg signed [10:0] fov;
    reg [23:0] vacc_n;
    f_start <= 1'b0;
    if (CE_PIXEL) begin
        m_old_hs <= VGA_HS;
        m_old_vs <= VGA_VS;
        m_old_de <= VGA_DE;
        hcol <= hcol + 1'd1;
        if (~m_old_de & VGA_DE) begin
            hde0 <= hcol;
            if (de_first) begin
                lde0     <= vline;
                de_first <= 1'b0;
            end
        end
        if (~m_old_hs & VGA_HS) begin
            hcol    <= 9'd0;
            vline_n  = (~m_old_vs & VGA_VS) ? 9'd0 : vline + 1'd1;
            vline   <= vline_n;
            // fetch the source row for the NEXT output line (it is displayed during the next native line)
            fov = $signed({2'b0, vline_n}) + 11'sd1 - vstart_r;
            if (fov >= 0 && fov < $signed({2'b0, out_h})) begin
                vacc_n = (fov == 0) ? {4'd0, inc[20:1]} : (vacc + {3'd0, inc});
                vacc  <= vacc_n;
                f_row <= vacc_n[23:16];   // < SRC_H = 256 by construction (accumulator stays below 256 << 16)
                f_buf <= fov[0];
                f_start <= 1'b1;
            end
        end else if (~m_old_vs & VGA_VS) begin
            vline <= 9'd0;
        end
        if (~m_old_vs & VGA_VS) begin
            de_first <= 1'b1;
            if (vline > 9'd200) vtot <= vline + 1'd1;   // a whole frame was counted
        end
    end
end

// ====================================================================================================================
// Fetch state machine: 7 read bursts of 16 words per row into the line buffer half f_buf
// ====================================================================================================================
(* ramstyle = "MLAB, no_rw_check" *) reg [63:0] lb [0:255];
reg  [7:0] lb_wa = 0;
reg        lb_we = 0;
reg [63:0] lb_wd = 0;
reg  [7:0] lb_ra = 0;
reg [63:0] lb_q  = 0;

always @(posedge CLK_VIDEO) begin
    if (lb_we) lb[lb_wa] <= lb_wd;
    lb_q <= lb[lb_ra];
end

reg        rd_req_t = 0, rd_ack_t = 0;   // read command handshake (toggle request, toggle acknowledge)
wire       rd_pend = (rd_req_t != rd_ack_t);
reg [28:0] rd_addr = 0;
reg  [3:0] fs_burst = 0;
reg        fs_rot = 0;
wire [3:0] fs_nburst = fs_rot ? 4'd7 : 4'd8;          // bursts of 16 words a row: 112 words rotated, 128 words raw
wire [7:0] fs_lastbeat = fs_rot ? 8'd111 : 8'd127;
reg        fs_busy = 0;
reg  [7:0] fs_row = 0;
reg        fs_buf = 0;
reg  [7:0] beat = 0;
wire [14:0] fs_rowbase = fs_rot ? ({fs_row, 6'd0} + {1'b0, fs_row, 5'd0} + {2'b0, fs_row, 4'd0})   // row * 112
                                : {fs_row[7:0], 7'd0};                                              // row * 128

always @(posedge CLK_VIDEO) begin
    lb_we <= 1'b0;
    if (f_start) begin
        fs_busy  <= 1'b1;
        fs_row   <= f_row;
        fs_buf   <= f_buf;
        fs_burst <= 4'd0;
        fs_rot   <= rm_rot;
        beat     <= 8'd0;
    end else if (fs_busy && !rd_pend && fs_burst != fs_nburst) begin
        rd_addr  <= {CRT_MEM_BASE, 6'd0, rbuf, fs_rowbase + {7'd0, fs_burst, 4'd0}};
        rd_req_t <= ~rd_req_t;
        fs_burst <= fs_burst + 1'd1;
    end
    if (DDRAM_DOUT_READY) begin
        lb_we <= 1'b1;
        lb_wa <= {fs_buf, beat[6:0]};
        lb_wd <= DDRAM_DOUT;
        beat  <= beat + 1'd1;
        if (beat == fs_lastbeat) fs_busy <= 1'b0;
    end
end

// ====================================================================================================================
// DDR3 command arbiter: read command first, then fifo A (HDMI, never starved), then fifo B (CRT).
// One command is held on the output registers until DDRAM_BUSY is low (Avalon rule), commands issue back to back.
// ====================================================================================================================
reg        o_we = 0, o_rd = 0;
reg [28:0] o_addr = 0;
reg [63:0] o_din = 0;
reg  [7:0] o_be = 0;
reg  [7:0] o_burst = 8'd1;

assign DDRAM_WE       = o_we;
assign DDRAM_RD       = o_rd;
assign DDRAM_ADDR     = o_addr;
assign DDRAM_DIN      = o_din;
assign DDRAM_BE       = o_be;
assign DDRAM_BURSTCNT = o_burst;

wire o_free = ~(o_we | o_rd) | ~DDRAM_BUSY;

always @(posedge CLK_VIDEO) begin
    if (o_free) begin
        o_we <= 1'b0;
        o_rd <= 1'b0;
        if (rd_pend) begin
            o_rd     <= 1'b1;
            o_addr   <= rd_addr;
            o_burst  <= 8'd16;
            rd_ack_t <= rd_req_t;
        end else if (!fa_empty) begin
            o_we     <= 1'b1;
            o_addr   <= fa_q[60:32];
            o_din    <= {fa_q[31:0], fa_q[31:0]};
            o_be     <= fa_q[61] ? 8'hF0 : 8'h0F;
            o_burst  <= 8'd1;
            fa_rp    <= fa_rp + 1'd1;
        end else if (!fb_empty) begin
            o_we     <= 1'b1;
            o_addr   <= fb_q[60:32];
            o_din    <= {fb_q[31:0], fb_q[31:0]};
            o_be     <= fb_q[61] ? 8'hF0 : 8'h0F;
            o_burst  <= 8'd1;
            fb_rp    <= fb_rp + 1'd1;
        end
    end
end

// ====================================================================================================================
// Output pixel pipeline (pixel clock): picture window, nearest neighbour horizontal scale, line buffer read
// ====================================================================================================================
reg [23:0] hacc = 0;
reg        p1_valid = 0, p1_lsb = 0;
reg        hs_d1 = 0, vs_d1 = 0, de_d1 = 0, p1_show = 0;
reg  [7:0] r_d1 = 0, g_d1 = 0, b_d1 = 0;      // the raw native pixel, delayed like the rotated one (used while rotation is off)
reg  [7:0] r_q = 0, g_q = 0, b_q = 0;
reg        de_q = 0, hs_q = 0, vs_q = 0;

wire signed [10:0] ov_s   = $signed({2'b0, vline}) - vstart_r;
wire               ov_ok  = (ov_s >= 0) && (ov_s < $signed({2'b0, out_h}));
wire signed [10:0] hp_s   = $signed({2'b0, hcol}) - hstart_r;
wire               hp_ok  = (hp_s >= 0) && (hp_s < $signed({2'b0, out_w}));
wire               show   = crt_ok & crt_act_frame;

assign crt_ready = show;

always @(posedge CLK_VIDEO) if (CE_PIXEL) begin
    reg [23:0] hacc_n;
    reg  [7:0] sc;
    hacc_n = (hp_s == 0) ? {4'd0, inc[20:1]} : (hacc + {3'd0, inc});
    sc     = rm_rot ? ((hacc_n[23:16] > 8'd223) ? 8'd223 : hacc_n[23:16]) : hacc_n[23:16];   // source column of this output pixel (raw: 0..255)
    if (ov_ok && hp_ok) hacc <= hacc_n;
    p1_valid <= show & ov_ok & hp_ok;
    p1_lsb   <= sc[0];
    lb_ra    <= {ov_s[0], sc[7:1]};
    p1_show  <= show;
    hs_d1    <= VGA_HS;
    vs_d1    <= VGA_VS;
    de_d1    <= VGA_DE;
    r_d1     <= VGA_R;
    g_d1     <= VGA_G;
    b_d1     <= VGA_B;

    // Output stage. The outputs are ALWAYS this pipeline: the rotated picture while crt_ready, the raw native raster otherwise, both
    // delayed by the same two pixel clocks as the sync, so the core can wire crt_* to the analog pins permanently (no glitch when the
    // option changes, the raw raster is only shifted by a constant two pixel clocks).
    de_q <= de_d1;                         // the picture enable stays the native one in both modes (the OSD sizes itself from it)
    hs_q <= hs_d1;
    vs_q <= vs_d1;
    r_q  <= p1_show ? (p1_valid ? (p1_lsb ? lb_q[39:32] : lb_q[7:0])   : 8'd0) : r_d1;
    g_q  <= p1_show ? (p1_valid ? (p1_lsb ? lb_q[47:40] : lb_q[15:8])  : 8'd0) : g_d1;
    b_q  <= p1_show ? (p1_valid ? (p1_lsb ? lb_q[55:48] : lb_q[23:16]) : 8'd0) : b_d1;
end

assign crt_r  = r_q;
assign crt_g  = g_q;
assign crt_b  = b_q;
assign crt_de = de_q;
assign crt_hs = hs_q;
assign crt_vs = vs_q;

endmodule
