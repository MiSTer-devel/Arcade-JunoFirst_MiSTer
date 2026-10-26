# Arcade-JunoFirst input path for gen.py (controllers.sv wave-2 integration, CTL-2026-10-25)
OLD_TOP = '/tmp/claude-1000/-Work-Projects-ZZZ-Obsidian-FPGA-FPGA-Brain/dc91ce13-5119-4157-a49b-c12bf7ecc11d/scratchpad/controllers/wave2A/junofirst/Arcade-JunoFirst.sv.orig'
NEW_TOP = '/Work/Projects/ZZZ_Obsidian_FPGA/FPGA-Brain/Projects/Arcade-JunoFirst_MiSTer/Arcade-JunoFirst.sv'
CHUNKS = [('///////////////////         Keyboard', 'pause #(8,8,8,49) pause', 'excl')]   # keyboard .. m_* .. kb instance
PRE = [('wire pause_cpu;\n', '')]
PORTS = '''    input         CLK_49M, pause_cpu,
    input  [10:0] ps2_key,
    input  [15:0] joystick_0, joystick_1,
    output [16:0] o'''
OUT = ('assign o = {m_up1, m_down1, m_left1, m_right1, m_fire1, m_warp1, m_up2, m_down2, m_left2, m_right2, m_fire2, m_warp2,\n'
       '            m_start1, m_start2, m_coin1, m_coin2, m_pause};')
EDITS = {}   # keys already acted on press here: no intended difference
