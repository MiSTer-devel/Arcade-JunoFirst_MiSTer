-------------------------------------------------------------------------------
--
-- T8022 Microcontroller System
--
-- Copyright (c) 2004-2023, Arnim Laeuger (arniml@opencores.org)
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

entity t8022 is

  port (
    xtal_i    : in    std_logic;
    reset_i   : in    std_logic;
    ale_o     : out   std_logic;
    t0_i      : in    std_logic;
    t1_i      : in    std_logic;
    p2_b      : inout std_logic_vector( 7 downto 0);
    p1_b      : inout std_logic_vector( 7 downto 0);
    p0_b      : inout std_logic_vector( 7 downto 0);
    prog_n_o  : out   std_logic;
    an0_i     : in    std_logic_vector( 7 downto 0);
    an1_i     : in    std_logic_vector( 7 downto 0)
  );

end t8022;


library ieee;
use ieee.numeric_std.all;

architecture struct of t8022 is

  signal p2_s             : std_logic_vector( 7 downto 0);
  signal p1_s             : std_logic_vector( 7 downto 0);
  signal p0_s             : std_logic_vector( 7 downto 0);

begin

  t8022_notri_b : entity work.t8022_notri
    generic map (
      -- we don't need explicit gating of input ports
      -- this is done implicitely by the bidirectional pads
      gate_port_input_g => 0
    )

    port map (
      xtal_i    => xtal_i,
      xtal_en_i => '1',
      reset_i   => reset_i,
      ale_o     => ale_o,
      t0_i      => t0_i,
      t1_i      => t1_i,
      p2_i      => p2_b,
      p2_o      => p2_s,
      p1_i      => p1_b,
      p1_o      => p1_s,
      p0_i      => p0_b,
      p0_o      => p0_s,
      prog_n_o  => prog_n_o,
      an0_i     => an0_i,
      an1_i     => an1_i
    );

  -----------------------------------------------------------------------------
  -- Process bidirs
  --
  -- Purpose:
  --   Assign bidirectional signals.
  --
  bidirs: process (p0_b, p0_s,
                   p1_b, p1_s,
                   p2_b, p2_s)

    function port_bidir_f(port_value : in std_logic_vector;
                          low_imp    : in std_logic) return std_logic_vector is
      variable result_v : std_logic_vector(port_value'range);
    begin
      for idx in port_value'high downto port_value'low loop
        if low_imp = '1' then
          result_v(idx) := port_value(idx);
        elsif port_value(idx) = '0' then
          result_v(idx) := '0';
        else
          result_v(idx) := 'Z';
        end if;
      end loop;

      return result_v;
    end;

  begin
    -- Port 0 -----------------------------------------------------------------
    p0_b <= port_bidir_f(port_value => p0_s,
                         low_imp    => '0');

    -- Port 1 -----------------------------------------------------------------
    p1_b <= port_bidir_f(port_value => p1_s,
                         low_imp    => '0');

    -- Port 2 -----------------------------------------------------------------
    p2_b <= port_bidir_f(port_value => p2_s,
                         low_imp    => '0');

  end process bidirs;
  --
  -----------------------------------------------------------------------------


end struct;
