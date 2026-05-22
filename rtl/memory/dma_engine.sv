// Module: dma_engine
// Purpose: Blocking word-copy DMA across HBM, CMEM, VMEM0, and VMEM1.
// Public TPU inspiration: Explicit DMA moves tensors between global and local memories.
// Educational simplification: One aligned 32-bit transfer is in flight at a time.
// Inputs: dma_cmd_t command plus memory responses.
// Outputs: request ports for HBM/CMEM/VMEM0/VMEM1 and unit status.
// State: IDLE -> READ_REQ/READ_WAIT -> WRITE_REQ/WRITE_WAIT -> DONE/ERROR.
// Latency: Determined by target memory responses.
// Backpressure: cmd_ready is high only in IDLE.
// Error behavior: Bad spaces, alignment, bounds, or memory response errors enter ERROR.
// Zero-length semantics: valid aligned zero-length DMAs are no-op commands with a one-cycle done pulse.
module dma_engine #(
  parameter int HBM_BYTES = 1048576,
  parameter int CMEM_BYTES = 524288,
  parameter int VMEM_BYTES = 262144
)(
  input  logic clk,
  input  logic rst_n,
  input  vtpu_pkg::dma_cmd_t cmd,
  input  logic cmd_valid,
  output logic cmd_ready,
  output vtpu_pkg::unit_status_t status,

  output vtpu_pkg::mem_req_t hbm_req,
  input  vtpu_pkg::mem_resp_t hbm_resp,

  output vtpu_pkg::vmem_req_t cmem_req,
  input  vtpu_pkg::vmem_resp_t cmem_resp,

  output vtpu_pkg::vmem_req_t vmem0_req,
  input  vtpu_pkg::vmem_resp_t vmem0_resp,

  output vtpu_pkg::vmem_req_t vmem1_req,
  input  vtpu_pkg::vmem_resp_t vmem1_resp,

  output logic [31:0] bytes_moved_pulse
);
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_READ_REQ,
    ST_READ_WAIT,
    ST_WRITE_REQ,
    ST_WRITE_WAIT,
    ST_DONE,
    ST_ERROR
  } state_t;

  state_t state_q;
  vtpu_pkg::dma_cmd_t cmd_q;
  logic [31:0] offset_q;
  logic [31:0] data_q;
  logic [7:0] error_code_q;

  vtpu_pkg::mem_req_t hbm_req_q;
  vtpu_pkg::vmem_req_t cmem_req_q;
  vtpu_pkg::vmem_req_t vmem0_req_q;
  vtpu_pkg::vmem_req_t vmem1_req_q;

  assign hbm_req = hbm_req_q;
  assign cmem_req = cmem_req_q;
  assign vmem0_req = vmem0_req_q;
  assign vmem1_req = vmem1_req_q;

  assign cmd_ready = (state_q == ST_IDLE);
  assign status.busy = (state_q == ST_READ_REQ) ||
                       (state_q == ST_READ_WAIT) ||
                       (state_q == ST_WRITE_REQ) ||
                       (state_q == ST_WRITE_WAIT);
  assign status.done = (state_q == ST_DONE);
  assign status.error = (state_q == ST_ERROR);
  assign status.error_code = (state_q == ST_ERROR) ? error_code_q : vtpu_pkg::ERR_NONE;

  function automatic logic valid_space(input logic [2:0] space);
    valid_space = (space == vtpu_pkg::MEM_HBM) ||
                  (space == vtpu_pkg::MEM_CMEM) ||
                  (space == vtpu_pkg::MEM_VMEM0) ||
                  (space == vtpu_pkg::MEM_VMEM1);
  endfunction

  function automatic logic [31:0] mem_size(input logic [2:0] space);
    unique case (space)
      vtpu_pkg::MEM_HBM: mem_size = HBM_BYTES;
      vtpu_pkg::MEM_CMEM: mem_size = CMEM_BYTES;
      vtpu_pkg::MEM_VMEM0,
      vtpu_pkg::MEM_VMEM1: mem_size = VMEM_BYTES;
      default: mem_size = 32'd0;
    endcase
  endfunction

  function automatic logic range_ok(input logic [2:0] space, input logic [31:0] addr, input logic [31:0] len);
    range_ok = valid_space(space) && ((addr + len) <= mem_size(space)) && ((addr + len) >= addr);
  endfunction

  function automatic logic selected_ready(input logic [2:0] space);
    unique case (space)
      vtpu_pkg::MEM_HBM: selected_ready = hbm_resp.ready;
      vtpu_pkg::MEM_CMEM: selected_ready = cmem_resp.ready;
      vtpu_pkg::MEM_VMEM0: selected_ready = vmem0_resp.ready;
      vtpu_pkg::MEM_VMEM1: selected_ready = vmem1_resp.ready;
      default: selected_ready = 1'b0;
    endcase
  endfunction

  function automatic logic selected_req_valid(input logic [2:0] space);
    unique case (space)
      vtpu_pkg::MEM_HBM: selected_req_valid = hbm_req_q.valid;
      vtpu_pkg::MEM_CMEM: selected_req_valid = cmem_req_q.valid;
      vtpu_pkg::MEM_VMEM0: selected_req_valid = vmem0_req_q.valid;
      vtpu_pkg::MEM_VMEM1: selected_req_valid = vmem1_req_q.valid;
      default: selected_req_valid = 1'b0;
    endcase
  endfunction

  function automatic logic selected_valid(input logic [2:0] space);
    unique case (space)
      vtpu_pkg::MEM_HBM: selected_valid = hbm_resp.valid;
      vtpu_pkg::MEM_CMEM: selected_valid = cmem_resp.valid;
      vtpu_pkg::MEM_VMEM0: selected_valid = vmem0_resp.valid;
      vtpu_pkg::MEM_VMEM1: selected_valid = vmem1_resp.valid;
      default: selected_valid = 1'b0;
    endcase
  endfunction

  function automatic logic selected_error(input logic [2:0] space);
    unique case (space)
      vtpu_pkg::MEM_HBM: selected_error = hbm_resp.error;
      vtpu_pkg::MEM_CMEM: selected_error = cmem_resp.error;
      vtpu_pkg::MEM_VMEM0: selected_error = vmem0_resp.error;
      vtpu_pkg::MEM_VMEM1: selected_error = vmem1_resp.error;
      default: selected_error = 1'b1;
    endcase
  endfunction

  function automatic logic [31:0] selected_rdata(input logic [2:0] space);
    unique case (space)
      vtpu_pkg::MEM_HBM: selected_rdata = hbm_resp.rdata;
      vtpu_pkg::MEM_CMEM: selected_rdata = cmem_resp.rdata;
      vtpu_pkg::MEM_VMEM0: selected_rdata = vmem0_resp.rdata;
      vtpu_pkg::MEM_VMEM1: selected_rdata = vmem1_resp.rdata;
      default: selected_rdata = 32'd0;
    endcase
  endfunction

  task automatic clear_reqs;
    begin
      hbm_req_q <= '0;
      cmem_req_q <= '0;
      vmem0_req_q <= '0;
      vmem1_req_q <= '0;
    end
  endtask

  task automatic drive_read_req(input logic [2:0] space, input logic [31:0] addr);
    begin
      unique case (space)
        vtpu_pkg::MEM_HBM: begin
          hbm_req_q <= '{valid: 1'b1, write: 1'b0, space: vtpu_pkg::MEM_HBM, addr: addr, wdata: 32'd0, wstrb: 4'h0};
        end
        vtpu_pkg::MEM_CMEM: begin
          cmem_req_q <= '{valid: 1'b1, write: 1'b0, addr: addr, wdata: 32'd0, wstrb: 4'h0};
        end
        vtpu_pkg::MEM_VMEM0: begin
          vmem0_req_q <= '{valid: 1'b1, write: 1'b0, addr: addr, wdata: 32'd0, wstrb: 4'h0};
        end
        vtpu_pkg::MEM_VMEM1: begin
          vmem1_req_q <= '{valid: 1'b1, write: 1'b0, addr: addr, wdata: 32'd0, wstrb: 4'h0};
        end
        default: begin end
      endcase
    end
  endtask

  task automatic drive_write_req(input logic [2:0] space, input logic [31:0] addr, input logic [31:0] data);
    begin
      unique case (space)
        vtpu_pkg::MEM_HBM: begin
          hbm_req_q <= '{valid: 1'b1, write: 1'b1, space: vtpu_pkg::MEM_HBM, addr: addr, wdata: data, wstrb: 4'hF};
        end
        vtpu_pkg::MEM_CMEM: begin
          cmem_req_q <= '{valid: 1'b1, write: 1'b1, addr: addr, wdata: data, wstrb: 4'hF};
        end
        vtpu_pkg::MEM_VMEM0: begin
          vmem0_req_q <= '{valid: 1'b1, write: 1'b1, addr: addr, wdata: data, wstrb: 4'hF};
        end
        vtpu_pkg::MEM_VMEM1: begin
          vmem1_req_q <= '{valid: 1'b1, write: 1'b1, addr: addr, wdata: data, wstrb: 4'hF};
        end
        default: begin end
      endcase
    end
  endtask

  task automatic enter_error(input logic [7:0] code);
    begin
      clear_reqs();
      state_q <= ST_ERROR;
      error_code_q <= code;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      cmd_q <= '0;
      offset_q <= 32'd0;
      data_q <= 32'd0;
      error_code_q <= vtpu_pkg::ERR_NONE;
      bytes_moved_pulse <= 32'd0;
      clear_reqs();
    end else begin
      bytes_moved_pulse <= 32'd0;

      unique case (state_q)
        ST_IDLE: begin
          clear_reqs();
          if (cmd_valid) begin
            if (!valid_space(cmd.src_space) || !valid_space(cmd.dst_space)) begin
              enter_error(vtpu_pkg::ERR_UNSUPPORTED);
            end else if ((cmd.src_addr[1:0] != 2'b00) ||
                         (cmd.dst_addr[1:0] != 2'b00) ||
                         (cmd.len_bytes[1:0] != 2'b00)) begin
              enter_error(vtpu_pkg::ERR_UNALIGNED);
            end else if (!range_ok(cmd.src_space, cmd.src_addr, cmd.len_bytes) ||
                         !range_ok(cmd.dst_space, cmd.dst_addr, cmd.len_bytes)) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              cmd_q <= cmd;
              offset_q <= 32'd0;
              if (cmd.len_bytes == 32'd0) begin
                state_q <= ST_DONE;
              end else begin
                state_q <= ST_READ_REQ;
              end
            end
          end
        end
        ST_READ_REQ: begin
          if (selected_req_valid(cmd_q.src_space) && selected_ready(cmd_q.src_space)) begin
            clear_reqs();
            state_q <= ST_READ_WAIT;
          end else begin
            drive_read_req(cmd_q.src_space, cmd_q.src_addr + offset_q);
          end
        end
        ST_READ_WAIT: begin
          clear_reqs();
          if (selected_valid(cmd_q.src_space)) begin
            if (selected_error(cmd_q.src_space)) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              data_q <= selected_rdata(cmd_q.src_space);
              state_q <= ST_WRITE_REQ;
            end
          end
        end
        ST_WRITE_REQ: begin
          if (selected_req_valid(cmd_q.dst_space) && selected_ready(cmd_q.dst_space)) begin
            clear_reqs();
            state_q <= ST_WRITE_WAIT;
          end else begin
            drive_write_req(cmd_q.dst_space, cmd_q.dst_addr + offset_q, data_q);
          end
        end
        ST_WRITE_WAIT: begin
          clear_reqs();
          if (selected_valid(cmd_q.dst_space)) begin
            if (selected_error(cmd_q.dst_space)) begin
              enter_error(vtpu_pkg::ERR_BAD_ADDR);
            end else begin
              bytes_moved_pulse <= 32'd4;
              if ((offset_q + 32'd4) >= cmd_q.len_bytes) begin
                state_q <= ST_DONE;
              end else begin
                offset_q <= offset_q + 32'd4;
                state_q <= ST_READ_REQ;
              end
            end
          end
        end
        ST_DONE: begin
          clear_reqs();
          state_q <= ST_IDLE;
        end
        ST_ERROR: begin
          clear_reqs();
        end
        default: begin
          enter_error(vtpu_pkg::ERR_UNSUPPORTED);
        end
      endcase
    end
  end
endmodule
