-------------------------------------------------------------------------------
--
-- The UPI-41 BUS unit.
-- Implements the BUS port logic.
--
-- Copyright (c) 2004-2022, Arnim Laeuger (arniml@opencores.org)
--
-- All rights reserved
--
-- Redistribution and use in source and synthezised forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- Redistributions of source code must retain the above copyright notice,
-- this list of conditions and the following disclaimer.
--
-- Redistributions in synthesized form must reproduce the above copyright
-- notice, this list of conditions and the following disclaimer in the
-- documentation and/or other materials provided with the distribution.
--
-- Neither the name of the author nor the names of other contributors may
-- be used to endorse or promote products derived from this software without
-- specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
--
-- Please report bugs to the author, but before you do so, please
-- make sure that this is not a derivative work and that
-- you have the latest version of this file.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

use work.t48_pack.word_t;

entity upi41_db_bus is

  generic (
    is_type_a_g : integer := 1
  );
  port (
    -- Global Interface -------------------------------------------------------
    clk_i        : in  std_logic;
    res_i        : in  std_logic;
    en_clk_i     : in  boolean;
    -- UPI41 Bus Interface ----------------------------------------------------
    data_i       : in  word_t;
    data_o       : out word_t;
    write_bus_i  : in  boolean;
    read_bus_i   : in  boolean;
    write_sts_i  : in  boolean;
    set_f1_o     : out boolean;
    clear_f1_o   : out boolean;
    f0_i         : in  std_logic;
    f1_i         : in  std_logic;
    ibf_o        : out std_logic;
    obf_o        : out std_logic;
    int_n_o      : out std_logic;
    ibf_int_i    : in  boolean;
    en_dma_i     : in  boolean;
    en_flags_i   : in  boolean;
    -- P2 interface -----------------------------------------------------------
    write_p2_i   : in  boolean;
    mint_ibf_n_o : out std_logic;
    mint_obf_o   : out std_logic;
    dma_o        : out boolean;
    drq_o        : out std_logic;
    dack_n_i     : in  std_logic;
    -- BUS Interface ----------------------------------------------------------
    a0_i         : in  std_logic;
    cs_n_i       : in  std_logic;
    rd_n_i       : in  std_logic;
    wr_n_i       : in  std_logic;
    db_i         : in  word_t;
    db_o         : out word_t;
    db_dir_o     : out std_logic
  );

end upi41_db_bus;


use work.t48_pack.clk_active_c;
use work.t48_pack.res_active_c;
use work.t48_pack.bus_idle_level_c;
use work.t48_pack.to_stdLogic;

architecture rtl of upi41_db_bus is

  signal ibf_q, obf_q : std_logic;

  -- the BUS output register
  signal dbbin_q,
         dbbout_q : word_t;
  -- the BUS status register
  signal sts_q    : std_logic_vector(7 downto 4);

  signal dma_q,
         flags_q : boolean;

  signal set_f1_async_q,
         clr_f1_async_q  : boolean;

  signal set_obf_sync_q,
    res_ibf_sync_q,
    res_int_sync_q,
    clr_drq_sync_q,
    set_drq_sync_q,
    res_f1_ctrl_sync_q,
    set_f1_sync_q,
    clr_f1_sync_q : boolean;

begin

  -- pragma translate_off

  -- UPI41 configuration ------------------------------------------------------
  assert (is_type_a_g = 0) or (is_type_a_g = 1)
    report "is_type_a_g must be either 1 or 0!"
    severity failure;

  -- pragma translate_on


  master_block : block

    signal read_s    : boolean;
    signal ext_acc_s : boolean;
    signal dack_s    : boolean;

    -- resets for write path
    signal res_ibf_s,
           res_f1_ctrl_s,
           res_int_s,
           res_dbbin_s    : boolean;
    -- resets for read path
    signal set_obf_s,
           res_obf_s,
           res_status_s : boolean;
    -- resets for drq
    signal set_drq_s,
           res_drq_s  : boolean;
    signal clk_drq_s  : std_logic;

    signal status_q : word_t;

  begin

    dack_s    <= dack_n_i = '0' and dma_q;
    ext_acc_s <= cs_n_i = '0' or dack_s;
    read_s    <= ext_acc_s and rd_n_i = '0';

    ---------------------------------------------------------------------------
    -- Write path
    --
    res_ibf_s <= res_i = res_active_c or res_ibf_sync_q;
    ibf_p: process (res_ibf_s, wr_n_i)
    begin
      if res_ibf_s then
        ibf_q <= '0';
      elsif rising_edge(wr_n_i) then
        if ext_acc_s then
          ibf_q <= '1';
        end if;
      end if;
    end process ibf_p;
    --
    res_f1_ctrl_s <= res_i = res_active_c or res_f1_ctrl_sync_q;
    f1_ctrl_p: process (res_f1_ctrl_s, wr_n_i)
      variable a0_v : std_logic;
    begin
      if res_f1_ctrl_s then
        set_f1_async_q <= false;
        clr_f1_async_q <= false;
      elsif rising_edge(wr_n_i) then
        if ext_acc_s then
          if dack_s then
            a0_v := '0';
          else
            a0_v := a0_i;
          end if;
          if a0_v = '1' then
            set_f1_async_q <= true;
          else
            clr_f1_async_q <= true;
          end if;
        end if;
      end if;
    end process f1_ctrl_p;
    --
    res_int_s <= res_i = res_active_c or res_int_sync_q;
    int_p: process (res_int_s, wr_n_i)
    begin
      if res_int_s then
        int_n_o <= '1';
      elsif rising_edge(wr_n_i) then
        if ext_acc_s then
          int_n_o <= '0';
        end if;
      end if;
    end process int_p;
    --
    res_dbbin_s <= res_i = res_active_c;
    dbbin_p: process (res_dbbin_s, wr_n_i)
    begin
      if res_dbbin_s then
        dbbin_q <= (others => '0');
      elsif rising_edge(wr_n_i) then
        if ext_acc_s then
          dbbin_q <= db_i;
        end if;
      end if;
    end process dbbin_p;

    ---------------------------------------------------------------------------
    -- Read path
    --
    set_obf_s <= set_obf_sync_q;
    res_obf_s <= res_i = res_active_c;
    obf_p: process (set_obf_s, res_obf_s, rd_n_i)
    begin
      if res_obf_s then
        obf_q <= '0';
      elsif set_obf_s then
        obf_q <= '1';
      elsif rising_edge(rd_n_i) then
        if ext_acc_s and (a0_i = '0' or dack_s) then
          obf_q <= '0';
        end if;
      end if;
    end process obf_p;
    --
    res_status_s <= res_i = res_active_c;
    status_p: process (res_status_s, rd_n_i)
    begin
      if res_status_s then
        status_q <= (others => '0');
      elsif falling_edge(rd_n_i) then
        -- prevent change when master reads status:
        -- latch new status regardless of actual access with cs_n_i to
        -- avoid setup issues when rd_n_i is asserted together with cs_n_i
        if is_type_a_g = 1 then
          status_q <= sts_q  & f1_i & f0_i & ibf_q & obf_q;
        else
          status_q <= "0000" & f1_i & f0_i & ibf_q & obf_q;
        end if;
      end if;
    end process status_p;

    ---------------------------------------------------------------------------
    -- DRQ / DACK
    --
    set_drq_s <= set_drq_sync_q;
    res_drq_s <= res_i = res_active_c or clr_drq_sync_q;
    clk_drq_s <= rd_n_i and wr_n_i;
    drq_p: process (set_drq_s, res_drq_s, clk_drq_s)
    begin
      if res_drq_s then
        drq_o <= '0';
      elsif set_drq_s then
        drq_o <= '1';
      elsif falling_edge(clk_drq_s) then
        -- TODO: check setup time of DACK' to falling rd_n_i/wr_n_i
        if dack_s then
          drq_o <= '0';
        end if;
      end if;
    end process drq_p;

    db_o       <= dbbout_q when a0_i = '0' or dack_s else
                  status_q;
    db_dir_o   <= '1' when read_s else '0';

    mint_ibf_n_o <= '0' when flags_q and ibf_q = '1' else '1';
    mint_obf_o   <= '0' when flags_q and obf_q = '0' else '1';

  end block;


  mcu_ctrl_p: process (res_i, clk_i)
  begin
    if res_i = res_active_c then
      flags_q  <= false;
      dma_q    <= false;
      dbbout_q <= (others => '0');
      sts_q    <= (others => '0');
      --
      set_obf_sync_q <= false;
      res_ibf_sync_q <= false;
      res_int_sync_q <= false;
      clr_drq_sync_q <= false;
      set_drq_sync_q <= false;

    elsif clk_i'event and clk_i = clk_active_c then
      -- signals are active for 1 clk_i cycle
      -- they're used as asynchronous sets/resets in master_block
      set_obf_sync_q <= false;
      res_ibf_sync_q <= false;
      res_int_sync_q <= false;
      clr_drq_sync_q <= false;
      set_drq_sync_q <= false;

      if en_clk_i then
        if write_bus_i then
          dbbout_q       <= data_i;
          set_obf_sync_q <= true;
        elsif read_bus_i then
          res_ibf_sync_q <= true;
        elsif write_sts_i then
          sts_q          <= data_i(7 downto 4);
        end if;

        if ibf_int_i then
          res_int_sync_q <= true;
        end if;

        if is_type_a_g = 1 then
          if en_dma_i then
            dma_q          <= true;
            clr_drq_sync_q <= true;
          end if;
          if en_flags_i then
            flags_q        <= true;
          end if;

          if dma_q and write_p2_i and data_i(6) = '1' then
            set_drq_sync_q <= true;
          end if;
        end if;

      end if;
    end if;
  end process mcu_ctrl_p;

  f1_handshake_p: process (res_i, clk_i)
    variable set_f1_v : boolean;
    variable clr_f1_v : boolean;
  begin
    if res_i = res_active_c then
      res_f1_ctrl_sync_q <= false;
      set_f1_v           := false;
      clr_f1_v           := false;
      set_f1_sync_q      <= false;
      clr_f1_sync_q      <= false;

    elsif clk_i'event and clk_i = clk_active_c then
      set_f1_sync_q <= set_f1_v;
      clr_f1_sync_q <= clr_f1_v;

      res_f1_ctrl_sync_q <= set_f1_sync_q or clr_f1_sync_q;

      set_f1_v := set_f1_async_q;
      clr_f1_v := clr_f1_async_q;
    end if;
  end process f1_handshake_p;

  iobf_sync_p: process (res_i, clk_i)
    variable ibf_v : std_logic;
    variable obf_v : std_logic;
  begin
    if res_i = res_active_c then
      ibf_v := '0';
      obf_v := '0';
      ibf_o <= '0';
      obf_o <= '0';

    elsif clk_i'event and clk_i = clk_active_c then
      ibf_o <= ibf_v;
      obf_o <= obf_v;

      ibf_v := ibf_q;
      obf_v := obf_q;
    end if;
  end process iobf_sync_p;


  -----------------------------------------------------------------------------
  -- Output Mapping.
  -----------------------------------------------------------------------------
  set_f1_o   <= set_f1_sync_q;
  clear_f1_o <= clr_f1_sync_q;
  data_o     <=   dbbin_q
                when read_bus_i else
                  (others => bus_idle_level_c);


  dma_o <= dma_q;

end rtl;
