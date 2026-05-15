library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity bram_8bit is
    generic ( DEPTH : integer := 900 );
    port (
        clk  : in  std_logic;
        we   : in  std_logic;
        addr : in  integer;
        din  : in  std_logic_vector(7 downto 0);
        dout : out std_logic_vector(7 downto 0)
    );
end bram_8bit;

architecture Behavioral of bram_8bit is
    -- A clean 1D array that Vivado instantly recognizes
    type ram_type is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
    signal RAM : ram_type := (others => (others => '0'));
    
    -- Force Block RAM usage
    attribute ram_style : string;
    attribute ram_style of RAM : signal is "block";
begin
    process(clk)
    begin
        if rising_edge(clk) then
            -- Safe boundary check to prevent simulation crashes
            if addr < DEPTH then
                if we = '1' then
                    RAM(addr) <= din;
                end if;
                dout <= RAM(addr); -- Synchronous read
            else
                dout <= (others => '0'); -- Default safe fallback
            end if;
        end if;
    end process;
end Behavioral;