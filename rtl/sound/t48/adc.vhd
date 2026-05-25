-------------------------------------------------------------------------------
--
-- The T48 SAR ADC.
--
-- Copyright (c) 2023, Arnim Laeuger (arniml@opencores.org)
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
use work.t48_pack.mstate_t;

entity t48_adc is

  port (
    clk_i      : in  std_logic;
    res_i      : in  std_logic;
    en_clk_i   : in  boolean;
    ale_i      : in  boolean;
    mstate_i   : in  mstate_t;
    sel_an0_i  : in  boolean;
    sel_an1_i  : in  boolean;
    read_adc_i : in  boolean;
    data_o     : out word_t;
    sel_an_o   : out std_logic;
    sh_o       : out std_logic;
    sar_o      : out std_logic_vector(7 downto 0);
    comp_i     : in  std_logic
  );

end t48_adc;


use work.t48_pack.all;

architecture rtl of t48_adc is

  type adc_state_t is (ADC_SH,
                       ADC_B7, ADC_B6, ADC_B5, ADC_B4,
                       ADC_B3, ADC_B2, ADC_B1, ADC_B0);
  signal adc_state_q : adc_state_t;

  signal ale_q : boolean;

  signal sar_q, crr_q : word_t;

  signal start_conv_s : boolean;

begin

  start_conv_s <= sel_an0_i or sel_an1_i;

  process (res_i, clk_i)
  begin
    if res_i = res_active_c then
      ale_q       <= false;
      sar_q       <= (others => '0');
      crr_q       <= (others => '0');
      sel_an_o    <= '0';
      adc_state_q <= ADC_SH;

    elsif clk_i'event and clk_i = clk_active_c then
      if ale_i then
        ale_q <= true;
      elsif en_clk_i then
        ale_q <= ale_i;
      end if;

      if en_clk_i then
        if sel_an0_i then
          sel_an_o <= '0';
        elsif sel_an1_i then
          sel_an_o <= '1';
        end if;

        case adc_state_q is
          when ADC_SH =>
            if ale_q then
              adc_state_q <= ADC_B7;
              sar_q       <= "10000000";
            end if;

          when ADC_B7 =>
            if mstate_i = MSTATE1 then
              sar_q(7)    <= comp_i;
              sar_q(6)    <= '1';
              adc_state_q <= ADC_B6;
            end if;

          when ADC_B6 =>
            if mstate_i = MSTATE3 then
              sar_q(6)    <= comp_i;
              sar_q(5)    <= '1';
              adc_state_q <= ADC_B5;
            end if;

          when ADC_B5 =>
            if mstate_i = MSTATE1 then
              sar_q(5)    <= comp_i;
              sar_q(4)    <= '1';
              adc_state_q <= ADC_B4;
            end if;

          when ADC_B4 =>
            if mstate_i = MSTATE3 then
              sar_q(4)    <= comp_i;
              sar_q(3)    <= '1';
              adc_state_q <= ADC_B3;
            end if;

          when ADC_B3 =>
            if mstate_i = MSTATE1 then
              sar_q(3)    <= comp_i;
              sar_q(2)    <= '1';
              adc_state_q <= ADC_B2;
            end if;

          when ADC_B2 =>
            if mstate_i = MSTATE3 then
              sar_q(2)    <= comp_i;
              sar_q(1)    <= '1';
              adc_state_q <= ADC_B1;
            end if;

          when ADC_B1 =>
            if mstate_i = MSTATE1 then
              sar_q(1)    <= comp_i;
              sar_q(0)    <= '1';
              adc_state_q <= ADC_B0;
            end if;

          when ADC_B0 =>
            if mstate_i = MSTATE3 then
              sar_q(0)    <= comp_i;
              crr_q       <= sar_q(7 downto 1) & comp_i;
              adc_state_q <= ADC_SH;
            end if;

          when others =>
            adc_state_q <= ADC_SH;

        end case;
        --
        if start_conv_s then
          adc_state_q <= ADC_SH;
        end if;

      end if;
    end if;
  end process;


  -----------------------------------------------------------------------------
  -- Outpu mapping
  -----------------------------------------------------------------------------
  sh_o   <= '1' when adc_state_q = ADC_SH and ale_q and en_clk_i else '0';
  sar_o  <= sar_q;
  data_o <=   crr_q
            when read_adc_i else
              (others => bus_idle_level_c);

end rtl;
