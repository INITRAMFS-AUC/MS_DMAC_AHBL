/*
	Copyright 2020 Mohamed Shalan

	Licensed under the Apache License, Version 2.0 (the "License");
	you may not use this file except in compliance with the License.
	You may obtain a copy of the License at:

	http://www.apache.org/licenses/LICENSE-2.0

	Unless required by applicable law or agreed to in writing, software
	distributed under the License is distributed on an "AS IS" BASIS,
	WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
	See the License for the specific language governing permissions and
	limitations under the License.
*/

`timescale          1ns/1ps
`default_nettype    none

`include            "tb_utils.vh"

module MS_DMAC_AHBL_tb;

    localparam  CTRL_REG_OFF    =   8'h00,
                STATUS_REG_OFF  =   8'h04,
                SADDR_REG_OFF   =   8'h08,
                DADDR_REG_OFF   =   8'h0C,
                SIZE_REG_OFF    =   8'h10,
                TRIG_REG_OFF    =   8'h14,
                FC_REG_OFF      =   8'h18;

    localparam [31:0] SADDR = 32'h4000_0000;
    localparam [31:0] DADDR = 32'h5000_0000;
    localparam        XFER_SIZE = 16'h0004;

    wire        IRQ;
    reg         PIRQ;

    reg         HSEL;
    reg[31:0]   HADDR;
    reg[1:0]    HTRANS;
    reg         HWRITE;
    reg         HREADY;
    reg[31:0]   HWDATA;
    reg[2:0]    HSIZE;
    wire        HREADYOUT;
    wire[31:0]  HRDATA;

    wire [31:0]  M_HADDR;
    wire [1:0]   M_HTRANS;
    wire [2:0] 	 M_HSIZE;
    wire         M_HWRITE;
    wire [31:0]  M_HWDATA;
    reg          M_HREADY;
    reg [31:0]   M_HRDATA;

    `TB_CLK(HCLK, 20)
    `TB_SRSTN(HRESETn, HCLK, 173)
    `TB_DUMP("MS_DMAC_AHBL_tb.vcd", MS_DMAC_AHBL_tb, 0)
    `TB_FINISH(100_1000)

    `include            "ahbl_tasks.vh"

    MS_DMAC_AHBL DUV (
        .HCLK(HCLK),
        .HRESETn(HRESETn),

        .IRQ(IRQ),
        .PIRQ(PIRQ),

        .HSEL(HSEL),
        .HADDR(HADDR),
        .HTRANS(HTRANS),
        .HWRITE(HWRITE),
        .HREADY(HREADY),
        .HWDATA(HWDATA),
        .HSIZE(HSIZE),
        .HREADYOUT(HREADYOUT),
        .HRDATA(HRDATA),

        .M_HADDR(M_HADDR),
        .M_HTRANS(M_HTRANS),
        .M_HSIZE(M_HSIZE),
        .M_HWRITE(M_HWRITE),
        .M_HWDATA(M_HWDATA),
        .M_HREADY(M_HREADY),
        .M_HRDATA(M_HRDATA)
    );

    // ---------- Behavioral memory model (source + destination regions) ----------
    // Indexed by low-address byte offset. SADDR and DADDR share the same low bits,
    // but we key on the high-address bit to pick src vs dest.
    reg [7:0] src_mem  [0:255];
    reg [7:0] dest_mem [0:255];

    reg [31:0] addr_ph;          // latched address-phase address
    reg        write_ph;         // latched address-phase write flag
    reg [2:0]  size_ph;          // latched address-phase size
    reg        valid_ph;

    function is_src;
        input [31:0] a;
        is_src = (a[31:28] == 4'h4);
    endfunction

    // Address-phase capture
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            valid_ph <= 1'b0;
        end else if (M_HREADY) begin
            valid_ph <= (M_HTRANS == 2'b10);
            addr_ph  <= M_HADDR;
            write_ph <= M_HWRITE;
            size_ph  <= M_HSIZE;
        end
    end

    // Data-phase: drive read data / capture write data
    integer i;
    always @(*) begin
        M_HRDATA = 32'hDEAD_DEAD;
        if (valid_ph && !write_ph) begin
            if (is_src(addr_ph))
                M_HRDATA = {src_mem[addr_ph[7:0]+3], src_mem[addr_ph[7:0]+2],
                            src_mem[addr_ph[7:0]+1], src_mem[addr_ph[7:0]+0]};
            else
                M_HRDATA = {dest_mem[addr_ph[7:0]+3], dest_mem[addr_ph[7:0]+2],
                            dest_mem[addr_ph[7:0]+1], dest_mem[addr_ph[7:0]+0]};
        end
    end

    always @(posedge HCLK) begin
        if (valid_ph && write_ph && M_HREADY) begin
            // word write (HSIZE=2) captures 4 bytes
            if (is_src(addr_ph)) begin
                src_mem[addr_ph[7:0]+0] <= M_HWDATA[7:0];
                src_mem[addr_ph[7:0]+1] <= M_HWDATA[15:8];
                src_mem[addr_ph[7:0]+2] <= M_HWDATA[23:16];
                src_mem[addr_ph[7:0]+3] <= M_HWDATA[31:24];
            end else begin
                dest_mem[addr_ph[7:0]+0] <= M_HWDATA[7:0];
                dest_mem[addr_ph[7:0]+1] <= M_HWDATA[15:8];
                dest_mem[addr_ph[7:0]+2] <= M_HWDATA[23:16];
                dest_mem[addr_ph[7:0]+3] <= M_HWDATA[31:24];
            end
        end
    end

    // ---------- Checker ----------
    integer errors;
    integer irq_count;
    integer transfer_count;

    // Count completed transfers (rising edge on M_HTRANS[1] after last beat)
    // Simpler: count IRQ pulses.
    reg irq_d;
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            irq_d <= 0;
            irq_count <= 0;
        end else begin
            irq_d <= IRQ;
            if (IRQ && !irq_d) irq_count <= irq_count + 1;
        end
    end

    task check_dest_matches_src;
        input [31:0] nbytes;
        integer k;
        begin
            for (k = 0; k < nbytes; k = k + 1) begin
                if (dest_mem[k] !== src_mem[k]) begin
                    $display("  MISMATCH @byte %0d: src=0x%02x dest=0x%02x",
                             k, src_mem[k], dest_mem[k]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task clear_dest;
        integer k;
        begin
            for (k = 0; k < 256; k = k + 1) dest_mem[k] = 8'hxx;
        end
    endtask

    // ---------- Stimulus ----------
    integer j;
    initial begin
        errors = 0;
        PIRQ = 0;
        HREADY = 1;
        M_HREADY = 1;

        // Pre-load source memory with known pattern
        for (j = 0; j < 256; j = j + 1) begin
            src_mem[j]  = 8'hA0 + j[7:0];
            dest_mem[j] = 8'hxx;
        end

        @(posedge HRESETn);
        ahbl_w_write(SADDR_REG_OFF, SADDR);
        ahbl_w_write(DADDR_REG_OFF, DADDR);
        ahbl_w_write(SIZE_REG_OFF, XFER_SIZE);
        ahbl_w_write(FC_REG_OFF, 8'h02);
        ahbl_w_write(CTRL_REG_OFF, 32'h06_06_01_01);

        // Transfer 1: PIRQ-triggered
        #57;
        @(posedge HCLK) PIRQ = 1;
        @(posedge M_HTRANS[1]) PIRQ = 0;
        `TB_WAIT_FOR_CLOCK_CYC(HCLK, 25)

        $display("[TB] Transfer 1 (PIRQ) — checking destination...");
        check_dest_matches_src(XFER_SIZE);
        clear_dest;

        // Transfer 2: PIRQ-triggered (should raise IRQ: FC decrements to 0)
        @(posedge HCLK) PIRQ = 1;
        @(posedge M_HTRANS[1]) PIRQ = 0;
        `TB_WAIT_FOR_CLOCK_CYC(HCLK, 25)

        $display("[TB] Transfer 2 (PIRQ) — checking destination...");
        check_dest_matches_src(XFER_SIZE);
        clear_dest;

        // Switch to SW triggering
        ahbl_w_write(CTRL_REG_OFF, 32'h06_06_00_01);
        `TB_WAIT_FOR_CLOCK_CYC(HCLK, 5)
        ahbl_w_write(TRIG_REG_OFF, 1'h1);
        `TB_WAIT_FOR_CLOCK_CYC(HCLK, 40)

        $display("[TB] Transfer 3 (SW) — checking destination...");
        check_dest_matches_src(XFER_SIZE);

        // Final report
        $display("=====================================");
        $display("  IRQ pulses observed : %0d", irq_count);
        $display("  Byte mismatches     : %0d", errors);
        if (errors == 0 && irq_count >= 2)
            $display("  TEST PASSED");
        else
            $display("  TEST FAILED");
        $display("=====================================");
        $finish;
    end

endmodule
