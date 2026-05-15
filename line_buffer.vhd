library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- 1. Define the custom 2D Array Type for the 3x3 Window
package cnn_types is
    -- A single row of 3 pixels (8 bits each)
    type window_row is array (0 to 2) of std_logic_vector(7 downto 0);
    -- A 2D array made of 3 rows
    type window_3x3 is array (0 to 2) of window_row;
end package cnn_types;

-------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.cnn_types.all;

entity LineBuffer_3x3 is
    generic (
        DATA_WIDTH  : integer := 8;
        IMAGE_WIDTH : integer := 64
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        valid_in  : in  std_logic; -- FSM says "Pixel from BRAM is valid"
        pixel_in  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        
        window    : out window_3x3; -- The perfectly aligned 3x3 grid
        valid_out : out std_logic   -- Tells MAC Array "Start multiplying!"
    );
end LineBuffer_3x3;

architecture Behavioral of LineBuffer_3x3 is

    -- The FIFOs hold (IMAGE_WIDTH - 3) pixels because the window holds the last 3
    constant FIFO_DEPTH : integer := IMAGE_WIDTH - 3;
    type fifo_type is array (0 to FIFO_DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);

    signal row_buffer_0 : fifo_type := (others => (others => '0'));
    signal row_buffer_1 : fifo_type := (others => (others => '0'));

    -- Replace pixel_count with 2D tracking (X and Y coordinates)
    signal x_count : integer := 0;
    signal y_count : integer := 0;

    -- Internal signal to represent the 3x3 window so we can read and write to it
    signal int_window : window_3x3 := (others => (others => (others => '0')));

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                x_count <= 0;
                y_count <= 0;
                valid_out <= '0';
                int_window <= (others => (others => (others => '0')));
                row_buffer_0 <= (others => (others => '0'));
                row_buffer_1 <= (others => (others => '0'));
                
            elsif valid_in = '1' then
                
                -- STEP 1: TRACK X AND Y COORDINATES
                if x_count = IMAGE_WIDTH - 1 then
                    x_count <= 0;
                    y_count <= y_count + 1;
                else
                    x_count <= x_count + 1;
                end if;

                -- STEP 2: SHIFT THE 3x3 WINDOW (Right to Left)
                -- Top Row
                int_window(0)(0) <= int_window(0)(1);
                int_window(0)(1) <= int_window(0)(2);
                -- Middle Row
                int_window(1)(0) <= int_window(1)(1);
                int_window(1)(1) <= int_window(1)(2);
                -- Bottom Row
                int_window(2)(0) <= int_window(2)(1);
                int_window(2)(1) <= int_window(2)(2);

                -- STEP 3: FEED NEW DATA INTO THE RIGHT SIDE OF THE WINDOW
                -- Bottom Right gets the brand new pixel from BRAM
                int_window(2)(2) <= pixel_in;
                -- Middle Right gets the pixel falling out of FIFO 0
                int_window(1)(2) <= row_buffer_0(FIFO_DEPTH-1);
                -- Top Right gets the pixel falling out of FIFO 1
                int_window(0)(2) <= row_buffer_1(FIFO_DEPTH-1);

                -- STEP 4: SHIFT THE FIFOs
                for i in FIFO_DEPTH-1 downto 1 loop
                    row_buffer_0(i) <= row_buffer_0(i-1);
                    row_buffer_1(i) <= row_buffer_1(i-1);
                end loop;

                -- STEP 5: FEED THE FIFOs
                -- Pixels pushed out of the left side of the window go into the FIFOs
                row_buffer_0(0) <= int_window(2)(0);
                row_buffer_1(0) <= int_window(1)(0);

                -- STEP 6: BOUNDARY-AWARE CONTROL LOGIC
                -- y_count >= 2 ensures we have buffered at least two full rows + starting the 3rd.
                -- x_count >= 2 ensures the 3x3 window has fully moved into the new row (no edge smearing).
                if (y_count >= 2) and (x_count >= 2) then
                    valid_out <= '1';
                else
                    valid_out <= '0';
                end if;
                
            else
                valid_out <= '0'; -- Pause output if BRAM stops sending data
            end if;
        end if;
    end process;

    -- Wire the internal registers to the output port
    window <= int_window;

end Behavioral;