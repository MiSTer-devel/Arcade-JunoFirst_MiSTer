-------------------------------------------------------------------------------
--
-- T8039 Microcontroller — toplevel WITH external program ROM port
--
-- Derived from Arnim Laeuger's t8039_notri.vhd (the T48 author's reference
-- 8039 toplevel, opencores). This variant exposes the program-memory bus
-- (pmem_addr_o / pmem_data_i) so an external program ROM can be wired in,
-- and parameterises the internal data RAM size:
--   ram_addr_width_g = 7  -> 128 bytes (8039)
--   ram_addr_width_g = 6  -> 64  bytes (8035)
--
-- Everything else (clock/reset/xtal3 loopback contract, port input gating)
-- is preserved verbatim from the reference toplevel — the whole point of
-- using this wrapper is to inherit the author-blessed t48_core port map.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity t8039_notri_extrom is

  generic (
    gate_port_input_g : integer := 1;
    ram_addr_width_g  : integer := 7   -- 7 = 128B (8039), 6 = 64B (8035)
  );

  port (
    xtal_i        : in  std_logic;
    xtal_en_i     : in  std_logic;
    reset_n_i     : in  std_logic;
    t0_i          : in  std_logic;
    t0_o          : out std_logic;
    t0_dir_o      : out std_logic;
    int_n_i       : in  std_logic;
    ea_i          : in  std_logic;
    rd_n_o        : out std_logic;
    psen_n_o      : out std_logic;
    wr_n_o        : out std_logic;
    ale_o         : out std_logic;
    db_i          : in  std_logic_vector( 7 downto 0);
    db_o          : out std_logic_vector( 7 downto 0);
    db_dir_o      : out std_logic;
    t1_i          : in  std_logic;
    p2_i          : in  std_logic_vector( 7 downto 0);
    p2_o          : out std_logic_vector( 7 downto 0);
    p2l_low_imp_o : out std_logic;
    p2h_low_imp_o : out std_logic;
    p1_i          : in  std_logic_vector( 7 downto 0);
    p1_o          : out std_logic_vector( 7 downto 0);
    p1_low_imp_o  : out std_logic;
    prog_n_o      : out std_logic;
    -- External program ROM bus
    pmem_addr_o   : out std_logic_vector(11 downto 0);
    pmem_data_i   : in  std_logic_vector( 7 downto 0)
  );

end t8039_notri_extrom;


library ieee;
use ieee.numeric_std.all;

use work.t48_core_comp_pack.t48_core;
use work.t48_core_comp_pack.generic_ram_ena;

architecture struct of t8039_notri_extrom is

  signal xtal3_s          : std_logic;
  signal dmem_addr_s      : std_logic_vector( 7 downto 0);
  signal dmem_we_s        : std_logic;
  signal dmem_data_from_s : std_logic_vector( 7 downto 0);
  signal dmem_data_to_s   : std_logic_vector( 7 downto 0);

  signal p1_in_s,
         p1_out_s         : std_logic_vector( 7 downto 0);
  signal p2_in_s,
         p2_out_s         : std_logic_vector( 7 downto 0);

  signal vdd_s            : std_logic;

begin

  vdd_s <= '1';

  -----------------------------------------------------------------------------
  -- Check generics for valid values.
  -----------------------------------------------------------------------------
  -- pragma translate_off
  assert gate_port_input_g = 0 or gate_port_input_g = 1
    report "gate_port_input_g must be either 1 or 0!"
    severity failure;
  assert ram_addr_width_g = 6 or ram_addr_width_g = 7
    report "ram_addr_width_g must be 6 (8035, 64B) or 7 (8039, 128B)!"
    severity failure;
  -- pragma translate_on


  t48_core_b : t48_core
    generic map (
      xtal_div_3_g        => 1,
      register_mnemonic_g => 1,
      include_port1_g     => 1,
      include_port2_g     => 1,
      include_bus_g       => 1,
      include_timer_g     => 1,
      sample_t1_state_g   => 4
    )
    port map (
      xtal_i        => xtal_i,
      xtal_en_i     => xtal_en_i,
      reset_i       => reset_n_i,
      t0_i          => t0_i,
      t0_o          => t0_o,
      t0_dir_o      => t0_dir_o,
      int_n_i       => int_n_i,
      ea_i          => ea_i,
      rd_n_o        => rd_n_o,
      psen_n_o      => psen_n_o,
      wr_n_o        => wr_n_o,
      ale_o         => ale_o,
      db_i          => db_i,
      db_o          => db_o,
      db_dir_o      => db_dir_o,
      t1_i          => t1_i,
      p2_i          => p2_in_s,
      p2_o          => p2_out_s,
      p2l_low_imp_o => p2l_low_imp_o,
      p2h_low_imp_o => p2h_low_imp_o,
      p1_i          => p1_in_s,
      p1_o          => p1_out_s,
      p1_low_imp_o  => p1_low_imp_o,
      prog_n_o      => prog_n_o,
      clk_i         => xtal_i,
      en_clk_i      => xtal3_s,
      xtal3_o       => xtal3_s,
      dmem_addr_o   => dmem_addr_s,
      dmem_we_o     => dmem_we_s,
      dmem_data_i   => dmem_data_from_s,
      dmem_data_o   => dmem_data_to_s,
      pmem_addr_o   => pmem_addr_o,
      pmem_data_i   => pmem_data_i
    );


  -----------------------------------------------------------------------------
  -- Gate port 1 and 2 input bus with respective output value
  -----------------------------------------------------------------------------
  gate_ports: if gate_port_input_g = 1 generate
    p1_in_s <= p1_i and p1_out_s;
    p2_in_s <= p2_i and p2_out_s;
  end generate;

  pass_ports: if gate_port_input_g = 0 generate
    p1_in_s <= p1_i;
    p2_in_s <= p2_i;
  end generate;

  p1_o <= p1_out_s;
  p2_o <= p2_out_s;


  ram_b : generic_ram_ena
    generic map (
      addr_width_g => ram_addr_width_g,
      data_width_g => 8
    )
    port map (
      clk_i => xtal_i,
      a_i   => dmem_addr_s(ram_addr_width_g - 1 downto 0),
      we_i  => dmem_we_s,
      ena_i => vdd_s,
      d_i   => dmem_data_to_s,
      d_o   => dmem_data_from_s
    );

end struct;
