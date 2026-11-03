//
// vram_sdram.sv - GPU VRAM backend on the MiSTer SDRAM2 module.
//
// 16-bit SDR SDRAM, four banks, 512 columns per row. The GPU side takes
// 8-byte-aligned byte addresses and transfers 64-bit beats; DOUT_READY pulses
// once per returned read beat. Storage and transport only.
//

module vram_sdram
(
   input             init,
   input             clk,

   input             SDRAM_EN,
   inout      [15:0] SDRAM_DQ,
   output reg [12:0] SDRAM_A,
   output reg  [1:0] SDRAM_BA,
   output            SDRAM_nCS,
   output            SDRAM_nWE,
   output            SDRAM_nRAS,
   output            SDRAM_nCAS,
   output            SDRAM_CLK,

   output            vram_BUSY,
   input      [21:0] vram_WA,
   input      [63:0] vram_DIN,
   input       [7:0] vram_BE,
   input       [7:0] vram_BURSTCNT,
   input             vram_WE,
   input             vram_RD,
   output reg [63:0] vram_DOUT,
   output reg        vram_DOUT_READY
);

localparam integer CAS_LATENCY = 3;

localparam integer ZERO_BUBBLE_READ = 1;

localparam [3:0] C_RCD = 4'd1;
localparam [3:0] C_RP  = 4'd1;
localparam [3:0] C_RAS = 4'd4;
localparam [3:0] C_RFC = 4'd7;
localparam [3:0] C_WR  = 4'd2;
localparam [3:0] C_WTR = 4'd1;
localparam [3:0] C_MRD = 4'd3;
localparam [9:0] C_REFI = 10'd793;
localparam [15:0] C_INIT = 16'd20322;

localparam [2:0] CMD_LOADMODE  = 3'b000;
localparam [2:0] CMD_REFRESH   = 3'b001;
localparam [2:0] CMD_PRECHARGE = 3'b010;
localparam [2:0] CMD_ACTIVE    = 3'b011;
localparam [2:0] CMD_WRITE     = 3'b100;
localparam [2:0] CMD_READ      = 3'b101;
localparam [2:0] CMD_NOP       = 3'b111;

localparam [12:0] MODE_REG = {3'b000, 1'b0, 2'b00, 3'd3, 1'b0, 3'b010};

reg [2:0] command = CMD_NOP;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_nCS  = SDRAM_EN ? 1'b0 : 1'b1;

reg [15:0] dq_out = 16'd0;
reg [15:0] dq_in = 16'd0;

wire wr_drive;
reg [15:0] dq_oe = 16'd0;
always @(posedge clk) dq_oe <= {16{wr_drive}};

genvar dqi;
generate
   for (dqi = 0; dqi < 16; dqi = dqi + 1) begin : dq_iobuf
      assign SDRAM_DQ[dqi] = dq_oe[dqi] ? dq_out[dqi] : 1'bz;
   end
endgenerate

wire [21:0] input_wa   = vram_WA;
wire  [1:0] input_bank = input_wa[10:9];
wire  [8:0] input_col  = input_wa[8:0];
wire [10:0] input_row  = input_wa[21:11];

reg  [21:0] cur_wa = 22'd0;
wire  [8:0] cur_col  = cur_wa[8:0];
wire  [1:0] cur_bank = cur_wa[10:9];
wire [10:0] cur_row  = cur_wa[21:11];

reg [3:0] row_open = 4'b0000;
reg [10:0] row_tag [0:3];
wire input_hit  = row_open[input_bank] && row_tag[input_bank] == input_row;
wire input_miss = row_open[input_bank] && row_tag[input_bank] != input_row;
wire cur_hit    = row_open[cur_bank] && row_tag[cur_bank] == cur_row;
wire cur_miss   = row_open[cur_bank] && row_tag[cur_bank] != cur_row;

localparam [4:0]
   ST_INIT_WAIT    = 5'd0,
   ST_INIT_PRE     = 5'd1,
   ST_INIT_PREWAIT = 5'd2,
   ST_INIT_REFRESH = 5'd3,
   ST_INIT_REFW    = 5'd4,
   ST_INIT_MODE    = 5'd5,
   ST_INIT_MODEW   = 5'd6,
   ST_IDLE         = 5'd7,
   ST_PRE          = 5'd8,
   ST_PREWAIT      = 5'd9,
   ST_ACT          = 5'd10,
   ST_ACTWAIT      = 5'd11,
   ST_XFER         = 5'd12,
   ST_READ_DRAIN   = 5'd13,
   ST_RELEASE      = 5'd14,
   ST_REF_GUARD    = 5'd15,
   ST_REF_PRE      = 5'd16,
   ST_REF_PREWAIT  = 5'd17,
   ST_REF_CMD      = 5'd18,
   ST_REF_WAIT     = 5'd19;

reg [4:0] state = ST_INIT_WAIT;
reg       initialized = 1'b0;
reg       req_write = 1'b0;
reg [7:0] total_beats = 8'd1;
reg [7:0] beats_left = 8'd0;
reg [7:0] beats_returned = 8'd0;
reg [1:0] slot = 2'd0;
reg [63:0] write_data = 64'd0;
reg [7:0]  write_be = 8'd0;

reg        pending_fast_valid = 1'b0;
reg [21:0] pending_fast_wa = 22'd0;
reg [63:0] pending_fast_data = 64'd0;
reg [7:0]  pending_fast_be = 8'd0;
reg [7:0]  pending_fast_burst = 8'd1;

wire [7:0] incoming_write_words =
    (vram_BURSTCNT >= 8'd1 && vram_BURSTCNT <= 8'd16) ? vram_BURSTCNT : 8'd1;
reg [3:0] wait_tmr = 4'd0;
reg [3:0] wtr_tmr = 4'd0;
reg [3:0] ras_tmr [0:3];
reg [3:0] wr_tmr  [0:3];

reg [15:0] init_count = 16'd0;
reg [3:0]  init_refresh_left = 4'd8;
reg [9:0]  refresh_count = 10'd0;
reg [3:0]  refresh_due = 4'd0;

wire bank_guards_clear = (ras_tmr[0] == 0 && ras_tmr[1] == 0 &&
                          ras_tmr[2] == 0 && ras_tmr[3] == 0 &&
                          wr_tmr[0]  == 0 && wr_tmr[1]  == 0 &&
                          wr_tmr[2]  == 0 && wr_tmr[3]  == 0);

localparam integer CAPW = CAS_LATENCY + 7;
reg [CAPW-1:0] cap_sr = {CAPW{1'b0}};
reg [1:0] cap_word = 2'd0;
reg [47:0] read_low = 48'd0;
wire cap_busy = |cap_sr;

wire write_prefetch_ready = SDRAM_EN && initialized &&
                             (state == ST_XFER) && req_write &&
                             !pending_fast_valid && (slot == 2'd0 || slot == 2'd1 || slot == 2'd2) &&
                             !vram_RD;
wire vram_ready = SDRAM_EN && initialized &&
                  (((state == ST_IDLE) && (refresh_due == 0) &&
                    !(vram_RD && (wtr_tmr != 0))) || write_prefetch_ready);
assign vram_BUSY = ~vram_ready;

assign wr_drive = SDRAM_EN && !init && initialized &&
                  (state == ST_XFER) && req_write &&
                  ((slot != 2'd0) || cur_hit);

integer i;

always @(posedge clk) begin
   dq_in <= SDRAM_DQ;
   command <= CMD_NOP;
   SDRAM_A <= 13'd0;
   SDRAM_BA <= 2'd0;
   vram_DOUT_READY <= 1'b0;

   if (wait_tmr != 0) wait_tmr <= wait_tmr - 1'b1;
   if (wtr_tmr != 0)  wtr_tmr  <= wtr_tmr - 1'b1;
   for (i = 0; i < 4; i = i + 1) begin
      if (ras_tmr[i] != 0) ras_tmr[i] <= ras_tmr[i] - 1'b1;
      if (wr_tmr[i]  != 0) wr_tmr[i]  <= wr_tmr[i]  - 1'b1;
   end

   if (initialized) begin
      if (refresh_count == C_REFI) begin
         refresh_count <= 10'd0;
         if (refresh_due != 4'hF) refresh_due <= refresh_due + 1'b1;
      end else begin
         refresh_count <= refresh_count + 1'b1;
      end
   end

   cap_sr <= {1'b0, cap_sr[CAPW-1:1]};
   if (cap_sr[0]) begin
      case (cap_word)
         2'd0: read_low[15:0]  <= dq_in;
         2'd1: read_low[31:16] <= dq_in;
         2'd2: read_low[47:32] <= dq_in;
         2'd3: begin
            vram_DOUT <= {dq_in, read_low};
            vram_DOUT_READY <= 1'b1;
            beats_returned <= beats_returned + 1'b1;
         end
      endcase
      cap_word <= cap_word + 1'b1;
   end

   if (init || !SDRAM_EN) begin
      state <= ST_INIT_WAIT;
      initialized <= 1'b0;
      init_count <= 16'd0;
      init_refresh_left <= 4'd8;
      refresh_count <= 10'd0;
      refresh_due <= 4'd0;
      row_open <= 4'b0000;
      wait_tmr <= 4'd0;
      wtr_tmr <= 4'd0;
      cap_sr <= {CAPW{1'b0}};
      cap_word <= 2'd0;
      beats_returned <= 8'd0;
      total_beats <= 8'd1;
      beats_left <= 8'd0;
      slot <= 2'd0;
      pending_fast_valid <= 1'b0;
      pending_fast_wa <= 22'd0;
      pending_fast_data <= 64'd0;
      pending_fast_be <= 8'd0;
      pending_fast_burst <= 8'd1;
      for (i = 0; i < 4; i = i + 1) begin
         ras_tmr[i] <= 4'd0;
         wr_tmr[i] <= 4'd0;
         row_tag[i] <= 11'd0;
      end
   end else begin
      if (write_prefetch_ready && vram_WE) begin
         pending_fast_valid <= 1'b1;
         pending_fast_wa    <= input_wa;
         pending_fast_data  <= vram_DIN;
         pending_fast_be    <= vram_BE;
         pending_fast_burst <= incoming_write_words;
      end

      case (state)

         ST_INIT_WAIT: begin
            if (init_count >= C_INIT) begin
               init_count <= 16'd0;
               state <= ST_INIT_PRE;
            end else begin
               init_count <= init_count + 1'b1;
            end
         end

         ST_INIT_PRE: begin
            command <= CMD_PRECHARGE;
            SDRAM_A[10] <= 1'b1;
            row_open <= 4'b0000;
            wait_tmr <= C_RP;
            state <= ST_INIT_PREWAIT;
         end

         ST_INIT_PREWAIT: begin
            if (wait_tmr == 0) state <= ST_INIT_REFRESH;
         end

         ST_INIT_REFRESH: begin
            command <= CMD_REFRESH;
            wait_tmr <= C_RFC;
            if (init_refresh_left != 0) init_refresh_left <= init_refresh_left - 1'b1;
            state <= ST_INIT_REFW;
         end

         ST_INIT_REFW: begin
            if (wait_tmr == 0) begin
               if (init_refresh_left == 0) state <= ST_INIT_MODE;
               else state <= ST_INIT_REFRESH;
            end
         end

         ST_INIT_MODE: begin
            command <= CMD_LOADMODE;
            SDRAM_A <= MODE_REG;
            wait_tmr <= C_MRD;
            state <= ST_INIT_MODEW;
         end

         ST_INIT_MODEW: begin
            if (wait_tmr == 0) begin
               initialized <= 1'b1;
               refresh_count <= 10'd0;
               refresh_due <= 4'd0;
               state <= ST_IDLE;
            end
         end

         ST_IDLE: begin
            if (refresh_due != 0) begin
               state <= ST_REF_GUARD;
            end else if ((vram_RD || vram_WE) && !(vram_RD && wtr_tmr != 0)) begin
               req_write <= vram_WE;
                        cur_wa <= input_wa;
               write_data <= vram_DIN;
               write_be <= vram_BE;
               total_beats <= vram_WE ? incoming_write_words :
                   ((vram_BURSTCNT == 0) ? 8'd1 : vram_BURSTCNT);
               beats_left <= vram_WE ? incoming_write_words :
                   ((vram_BURSTCNT == 0) ? 8'd1 : vram_BURSTCNT);
               beats_returned <= 8'd0;
               cap_word <= 2'd0;
               slot <= 2'd0;

               if (ZERO_BUBBLE_READ != 0 && vram_RD && input_hit && wtr_tmr == 0) begin
                  SDRAM_BA <= input_bank;
                  SDRAM_A[10] <= 1'b0;
                  SDRAM_A[9] <= 1'b0;
                  SDRAM_A[8:0] <= input_col;
                  SDRAM_A[12:11] <= 2'b00;
                  command <= CMD_READ;
                  cap_sr[CAS_LATENCY+1] <= 1'b1;
                  cap_sr[CAS_LATENCY+2] <= 1'b1;
                  cap_sr[CAS_LATENCY+3] <= 1'b1;
                  cap_sr[CAS_LATENCY+4] <= 1'b1;
                  slot <= 2'd1;
                  state <= ST_XFER;
               end else if (input_hit) begin
                  state <= ST_XFER;
               end else if (input_miss) begin
                  if (ras_tmr[input_bank] == 0 && wr_tmr[input_bank] == 0 && !cap_busy) begin
                     command <= CMD_PRECHARGE;
                     SDRAM_BA <= input_bank;
                     SDRAM_A[10] <= 1'b0;
                     row_open[input_bank] <= 1'b0;
                     wait_tmr <= C_RP;
                     state <= ST_PREWAIT;
                  end else begin
                     state <= ST_PRE;
                  end
               end else begin
                  command <= CMD_ACTIVE;
                  SDRAM_BA <= input_bank;
                  SDRAM_A[10:0] <= input_row;
                  row_open[input_bank] <= 1'b1;
                  row_tag[input_bank] <= input_row;
                  ras_tmr[input_bank] <= C_RAS;
                  wait_tmr <= C_RCD;
                  state <= ST_ACTWAIT;
               end
            end
         end

         ST_PRE: begin
            if (ras_tmr[cur_bank] == 0 && wr_tmr[cur_bank] == 0 && !cap_busy) begin
               command <= CMD_PRECHARGE;
               SDRAM_BA <= cur_bank;
               SDRAM_A[10] <= 1'b0;
               row_open[cur_bank] <= 1'b0;
               wait_tmr <= C_RP;
               state <= ST_PREWAIT;
            end
         end

         ST_PREWAIT: begin
            if (wait_tmr == 0) begin
               command <= CMD_ACTIVE;
               SDRAM_BA <= cur_bank;
               SDRAM_A[10:0] <= cur_row;
               row_open[cur_bank] <= 1'b1;
               row_tag[cur_bank] <= cur_row;
               ras_tmr[cur_bank] <= C_RAS;
               wait_tmr <= C_RCD;
               state <= ST_ACTWAIT;
            end
         end

         ST_ACT: begin
            command <= CMD_ACTIVE;
            SDRAM_BA <= cur_bank;
            SDRAM_A[10:0] <= cur_row;
            row_open[cur_bank] <= 1'b1;
            row_tag[cur_bank] <= cur_row;
            ras_tmr[cur_bank] <= C_RAS;
            wait_tmr <= C_RCD;
            state <= ST_ACTWAIT;
         end

         ST_ACTWAIT: begin
            if (wait_tmr == 0) begin
               if (!req_write && wtr_tmr == 0) begin
                  SDRAM_BA <= cur_bank;
                  SDRAM_A[10] <= 1'b0;
                  SDRAM_A[9] <= 1'b0;
                  SDRAM_A[8:0] <= cur_col;
                  SDRAM_A[12:11] <= 2'b00;
                  command <= CMD_READ;
                  cap_sr[CAS_LATENCY+1] <= 1'b1;
                  cap_sr[CAS_LATENCY+2] <= 1'b1;
                  cap_sr[CAS_LATENCY+3] <= 1'b1;
                  cap_sr[CAS_LATENCY+4] <= 1'b1;
                  slot <= 2'd1;
               end else begin
                  slot <= 2'd0;
               end
               state <= ST_XFER;
            end
         end

         ST_XFER: begin
            if (slot == 2'd0) begin
               if (!cur_hit) begin
                  if (cur_miss) begin
                     state <= ST_PRE;
                  end else begin
                     command <= CMD_ACTIVE;
                     SDRAM_BA <= cur_bank;
                     SDRAM_A[10:0] <= cur_row;
                     row_open[cur_bank] <= 1'b1;
                     row_tag[cur_bank] <= cur_row;
                     ras_tmr[cur_bank] <= C_RAS;
                     wait_tmr <= C_RCD;
                     state <= ST_ACTWAIT;
                  end
               end else if (!req_write && wtr_tmr != 0) begin
               end else begin
                  SDRAM_BA <= cur_bank;
                  SDRAM_A[10] <= 1'b0;
                  SDRAM_A[9] <= 1'b0;
                  SDRAM_A[8:0] <= cur_col;

                  if (req_write) begin
                     command <= CMD_WRITE;
                     dq_out <= write_data[15:0];
                     SDRAM_A[12:11] <= ~write_be[1:0];
                  end else begin
                     command <= CMD_READ;
                     SDRAM_A[12:11] <= 2'b00;
                     cap_sr[CAS_LATENCY+1] <= 1'b1;
                     cap_sr[CAS_LATENCY+2] <= 1'b1;
                     cap_sr[CAS_LATENCY+3] <= 1'b1;
                     cap_sr[CAS_LATENCY+4] <= 1'b1;
                  end
                  slot <= 2'd1;
               end
            end else if (slot == 2'd1) begin
               if (req_write) begin
                  dq_out <= write_data[31:16];
                  SDRAM_A[12:11] <= ~write_be[3:2];
               end
               slot <= 2'd2;
            end else if (slot == 2'd2) begin
               if (req_write) begin
                  dq_out <= write_data[47:32];
                  SDRAM_A[12:11] <= ~write_be[5:4];
               end
               slot <= 2'd3;
            end else begin
               if (req_write) begin
                  dq_out <= write_data[63:48];
                  SDRAM_A[12:11] <= ~write_be[7:6];
                  wr_tmr[cur_bank] <= C_WR;
                  wtr_tmr <= C_WTR;
               end

               cur_wa <= cur_wa + 22'd4;
               if (beats_left <= 1) begin
                  beats_left <= 8'd0;
                  slot <= 2'd0;
                  if (req_write && pending_fast_valid) begin
                     cur_wa             <= pending_fast_wa;
                     write_data         <= pending_fast_data;
                     write_be           <= pending_fast_be;
                     req_write          <= 1'b1;
                     pending_fast_valid <= 1'b0;
                     beats_left         <= pending_fast_burst;
                     total_beats        <= pending_fast_burst;
                     state              <= ST_XFER;
                  end else begin
                     if (req_write) state <= ST_RELEASE;
                     else state <= ST_READ_DRAIN;
                  end
               end else begin
                  beats_left <= beats_left - 1'b1;
                  slot <= 2'd0;
               end
            end
         end

         ST_READ_DRAIN: begin
            if (!cap_busy && beats_returned >= total_beats) state <= ST_RELEASE;
         end

         ST_RELEASE: begin
            state <= ST_IDLE;
         end

         ST_REF_GUARD: begin
            if (bank_guards_clear && !cap_busy) state <= ST_REF_PRE;
         end

         ST_REF_PRE: begin
            command <= CMD_PRECHARGE;
            SDRAM_A[10] <= 1'b1;
            row_open <= 4'b0000;
            wait_tmr <= C_RP;
            state <= ST_REF_PREWAIT;
         end

         ST_REF_PREWAIT: begin
            if (wait_tmr == 0) state <= ST_REF_CMD;
         end

         ST_REF_CMD: begin
            command <= CMD_REFRESH;
            if (refresh_due != 0) refresh_due <= refresh_due - 1'b1;
            wait_tmr <= C_RFC;
            state <= ST_REF_WAIT;
         end

         ST_REF_WAIT: begin
            if (wait_tmr == 0) begin
               if (refresh_due != 0) state <= ST_REF_CMD;
               else state <= ST_IDLE;
            end
         end

         default: state <= ST_INIT_WAIT;
      endcase
   end
end

altddio_out
#(
   .extend_oe_disable("OFF"),
   .intended_device_family("Cyclone V"),
   .invert_output("OFF"),
   .lpm_hint("UNUSED"),
   .lpm_type("altddio_out"),
   .oe_reg("UNREGISTERED"),
   .power_up_high("OFF"),
   .width(1)
)
sdramclk_ddr
(
   .datain_h(1'b0),
   .datain_l(1'b1),
   .outclock(clk),
   .dataout(SDRAM_CLK),
   .aclr(1'b0),
   .aset(1'b0),
   .oe(SDRAM_EN),
   .outclocken(1'b1),
   .sclr(1'b0),
   .sset(1'b0)
);

endmodule

module vram_sdram_2x3x
(
   input             init,
   input             clk_gpu,
   input             clk_ram,

   input             SDRAM_EN,
   inout      [15:0] SDRAM_DQ,
   output     [12:0] SDRAM_A,
   output      [1:0] SDRAM_BA,
   output            SDRAM_nCS,
   output            SDRAM_nWE,
   output            SDRAM_nRAS,
   output            SDRAM_nCAS,
   output            SDRAM_CLK,

   output            vram_BUSY,
   input      [27:0] vram_ADDR,
   input      [63:0] vram_DIN,
   input       [7:0] vram_BE,
   input       [7:0] vram_BURSTCNT,
   input             vram_WE,
   input             vram_RD,
   output reg [63:0] vram_DOUT,
   output reg        vram_DOUT_READY
);

function automatic [21:0] map_gpu_word_addr(input [27:0] a);
   reg [2:0] region;
   reg [22:0] byte_off;
   begin
      case (a[27:20])
         8'h00: region = 3'd0;
         8'h04: region = 3'd1;
         8'h05: region = 3'd2;
         8'h06: region = 3'd3;
         8'h07: region = 3'd4;
         default: region = 3'd5;
      endcase
      byte_off = {region,20'b0} + {3'b000,a[19:0]};
      map_gpu_word_addr = byte_off[22:1];
   end
endfunction

wire [21:0] gpu_wa = map_gpu_word_addr({1'b0, vram_ADDR[26:0]});

localparam integer CF_AW = 2;
localparam integer CF_W  = 104;
reg [CF_W-1:0] cf_mem [0:(1<<CF_AW)-1];
reg [CF_AW:0] cf_wbin = 0, cf_wgray = 0;
reg [CF_AW:0] cf_rbin = 0, cf_rgray = 0;
reg [CF_AW:0] cf_rgray_s1 = 0, cf_rgray_s2 = 0;
reg [CF_AW:0] cf_wgray_s1 = 0, cf_wgray_s2 = 0;

wire [CF_AW:0] cf_wbin_next  = cf_wbin + 1'b1;
wire [CF_AW:0] cf_wgray_next = (cf_wbin_next >> 1) ^ cf_wbin_next;
wire [CF_AW:0] cf_rbin_next  = cf_rbin + 1'b1;
wire [CF_AW:0] cf_rgray_next = (cf_rbin_next >> 1) ^ cf_rbin_next;
wire cf_full  = (cf_wgray_next == {~cf_rgray_s2[CF_AW:CF_AW-1], cf_rgray_s2[CF_AW-2:0]});
wire cf_empty = (cf_rgray == cf_wgray_s2);

wire gpu_req = vram_RD || vram_WE;

assign vram_BUSY = init || !SDRAM_EN || cf_full;
wire cf_push = gpu_req && !vram_BUSY;

always @(posedge clk_gpu) begin
   if (init) begin
      cf_wbin         <= 0;
      cf_wgray        <= 0;
      cf_rgray_s1     <= 0;
      cf_rgray_s2     <= 0;
   end else begin
      cf_rgray_s1 <= cf_rgray;
      cf_rgray_s2 <= cf_rgray_s1;

      if (cf_push) begin
         cf_mem[cf_wbin[CF_AW-1:0]] <= {
            vram_WE, vram_RD, gpu_wa, vram_DIN, vram_BE, vram_BURSTCNT
         };
         cf_wbin  <= cf_wbin_next;
         cf_wgray <= cf_wgray_next;
      end
   end
end

wire [CF_W-1:0] cf_head = cf_mem[cf_rbin[CF_AW-1:0]];

reg [CF_W-1:0] cmd_q = {CF_W{1'b0}};
reg            cmd_v = 1'b0;
wire           ram_busy;
wire           cmd_free = !cmd_v || !ram_busy;
wire           cf_pop   = cmd_free && !cf_empty;

wire        ram_we;
wire        ram_rd;
wire [21:0] ram_wa;
wire [63:0] ram_din;
wire  [7:0] ram_be;
wire  [7:0] ram_burst;
assign {ram_we, ram_rd, ram_wa, ram_din, ram_be, ram_burst} =
       cmd_v ? cmd_q : {CF_W{1'b0}};

wire [63:0] ram_dout;
wire        ram_dout_ready;

always @(posedge clk_ram) begin
   if (init) begin
      cf_rbin     <= 0;
      cf_rgray    <= 0;
      cf_wgray_s1 <= 0;
      cf_wgray_s2 <= 0;
      cmd_v       <= 1'b0;
   end else begin
      cf_wgray_s1 <= cf_wgray;
      cf_wgray_s2 <= cf_wgray_s1;

      if (cmd_v && !ram_busy) cmd_v <= 1'b0;
      if (cf_pop) begin
         cmd_q    <= cf_head;
         cmd_v    <= 1'b1;
         cf_rbin  <= cf_rbin_next;
         cf_rgray <= cf_rgray_next;
      end
   end
end

localparam integer RF_AW = 2;
reg [63:0] rf_mem [0:(1<<RF_AW)-1];
reg [RF_AW:0] rf_wbin = 0, rf_wgray = 0;
reg [RF_AW:0] rf_rbin = 0, rf_rgray = 0;
reg [RF_AW:0] rf_rgray_s1 = 0, rf_rgray_s2 = 0;
reg [RF_AW:0] rf_wgray_s1 = 0, rf_wgray_s2 = 0;

wire [RF_AW:0] rf_wbin_next  = rf_wbin + 1'b1;
wire [RF_AW:0] rf_wgray_next = (rf_wbin_next >> 1) ^ rf_wbin_next;
wire [RF_AW:0] rf_rbin_next  = rf_rbin + 1'b1;
wire [RF_AW:0] rf_rgray_next = (rf_rbin_next >> 1) ^ rf_rbin_next;
wire rf_full  = (rf_wgray_next == {~rf_rgray_s2[RF_AW:RF_AW-1], rf_rgray_s2[RF_AW-2:0]});
wire rf_empty = (rf_rgray == rf_wgray_s2);

always @(posedge clk_ram) begin
   if (init) begin
      rf_wbin      <= 0;
      rf_wgray     <= 0;
      rf_rgray_s1  <= 0;
      rf_rgray_s2  <= 0;
   end else begin
      rf_rgray_s1 <= rf_rgray;
      rf_rgray_s2 <= rf_rgray_s1;
      if (ram_dout_ready) begin
         if (!rf_full) begin
            rf_mem[rf_wbin[RF_AW-1:0]] <= ram_dout;
            rf_wbin  <= rf_wbin_next;
            rf_wgray <= rf_wgray_next;
         end
`ifndef SYNTHESIS
         else begin
            $error("vram_sdram_2x3x: response FIFO overflow");
         end
`endif
      end
   end
end

wire [63:0] rf_head_data = rf_mem[rf_rbin[RF_AW-1:0]];

always @(posedge clk_gpu) begin
   if (init) begin
      rf_rbin          <= 0;
      rf_rgray         <= 0;
      rf_wgray_s1      <= 0;
      rf_wgray_s2      <= 0;
      vram_DOUT        <= 64'd0;
      vram_DOUT_READY  <= 1'b0;
   end else begin
      rf_wgray_s1 <= rf_wgray;
      rf_wgray_s2 <= rf_wgray_s1;
      vram_DOUT_READY <= 1'b0;

      if (!rf_empty) begin
         vram_DOUT       <= rf_head_data;
         vram_DOUT_READY <= 1'b1;
         rf_rbin          <= rf_rbin_next;
         rf_rgray         <= rf_rgray_next;
      end
   end
end

vram_sdram ram_ctrl
(
   .init(init),
   .clk(clk_ram),

   .SDRAM_EN(SDRAM_EN),
   .SDRAM_DQ(SDRAM_DQ),
   .SDRAM_A(SDRAM_A),
   .SDRAM_BA(SDRAM_BA),
   .SDRAM_nCS(SDRAM_nCS),
   .SDRAM_nWE(SDRAM_nWE),
   .SDRAM_nRAS(SDRAM_nRAS),
   .SDRAM_nCAS(SDRAM_nCAS),
   .SDRAM_CLK(SDRAM_CLK),

   .vram_BUSY(ram_busy),
   .vram_WA(ram_wa),
   .vram_DIN(ram_din),
   .vram_BE(ram_be),
   .vram_BURSTCNT(ram_burst),
   .vram_WE(ram_we),
   .vram_RD(ram_rd),
   .vram_DOUT(ram_dout),
   .vram_DOUT_READY(ram_dout_ready)
);

endmodule

