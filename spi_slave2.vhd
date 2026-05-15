library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spi_slave is
    Port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        sclk     : in  std_logic;
        cs       : in  std_logic;
        mosi     : in  std_logic;
        miso     : out std_logic;
        tx_data  : in  std_logic_vector(7 downto 0);
        rx_data  : out std_logic_vector(7 downto 0);
        rx_valid : out std_logic;
        busy     : out std_logic
    );
end spi_slave;

architecture Behavioral of spi_slave is
    -- Clock synchronizers to prevent metastability
    signal sclk_sync : std_logic_vector(2 downto 0) := "000";
    signal cs_sync   : std_logic_vector(1 downto 0) := "11";
    signal mosi_sync : std_logic_vector(1 downto 0) := "00";
    
    signal bit_cnt   : integer range 0 to 7 := 7;
    signal rx_reg    : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_reg    : std_logic_vector(7 downto 0) := (others => '0');
    
    signal sclk_rising  : std_logic;
    signal sclk_falling : std_logic;
begin

    -- Synchronize incoming SPI signals to the 100MHz FPGA clock
    process(clk)
    begin
        if rising_edge(clk) then
            sclk_sync <= sclk_sync(1 downto 0) & sclk;
            cs_sync   <= cs_sync(0) & cs;
            mosi_sync <= mosi_sync(0) & mosi;
        end if;
    end process;

    sclk_rising  <= '1' when sclk_sync(2 downto 1) = "01" else '0';
    sclk_falling <= '1' when sclk_sync(2 downto 1) = "10" else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or cs_sync(1) = '1' then
                bit_cnt <= 7;
                rx_valid <= '0';
                busy <= '0';
                tx_reg <= tx_data; -- Pre-load first byte to send
            else
                rx_valid <= '0'; -- Ensure 1-clock cycle pulse
                busy <= '1';
                
                -- Mode 0: Sample MOSI on Rising Edge
                if sclk_rising = '1' then
                    rx_reg(bit_cnt) <= mosi_sync(1);
                end if;
                
                -- Mode 0: Shift state on Falling Edge
                if sclk_falling = '1' then
                    if bit_cnt = 0 then
                        bit_cnt <= 7;
                        rx_data <= rx_reg;
                        rx_valid <= '1';   -- Trigger the FSM
                        tx_reg <= tx_data; -- Load next byte instantly
                    else
                        bit_cnt <= bit_cnt - 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Drive MISO line (High-Z when CS is high)
    miso <= tx_reg(bit_cnt) when cs_sync(1) = '0' else 'Z';

end Behavioral;