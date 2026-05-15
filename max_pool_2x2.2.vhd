library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity max_pool_2x2 is
    generic (
        DATA_WIDTH  : integer := 8;
        IMAGE_WIDTH : integer := 62
    );
    port (
        clk       : in std_logic;
        rst       : in std_logic;
        valid_in  : in std_logic;
        pixel_in  : in unsigned(DATA_WIDTH-1 downto 0);
        max_out   : out unsigned(DATA_WIDTH-1 downto 0);
        valid_out : out std_logic
    );
end max_pool_2x2;

architecture Behavioral of max_pool_2x2 is
    type row_buffer_type is array (0 to IMAGE_WIDTH-1) of unsigned(DATA_WIDTH-1 downto 0);
    signal row_buf : row_buffer_type := (others => (others => '0'));

    signal x_cnt : integer range 0 to IMAGE_WIDTH-1 := 0;
    signal y_cnt : integer range 0 to IMAGE_WIDTH-1 := 0;

    signal top_left    : unsigned(DATA_WIDTH-1 downto 0) := (others => '0');
    signal bottom_left : unsigned(DATA_WIDTH-1 downto 0) := (others => '0');
begin
    process(clk)
        variable m1, m2, m_final : unsigned(DATA_WIDTH-1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                x_cnt <= 0;
                y_cnt <= 0;
                valid_out <= '0';
                max_out <= (others => '0');
            else
                valid_out <= '0'; -- Default to no output

                if valid_in = '1' then
                    
                    if y_cnt mod 2 = 0 then
                        -- EVEN ROW: Just store the pixel in the line buffer
                        row_buf(x_cnt) <= pixel_in;
                    else
                        -- ODD ROW: Compute the pooling
                        if x_cnt mod 2 = 0 then
                            -- Left column of the 2x2 window: Save to registers
                            top_left <= row_buf(x_cnt);
                            bottom_left <= pixel_in;
                        else
                            -- Right column of the 2x2 window: Compute the Maximum!
                            if top_left > row_buf(x_cnt) then m1 := top_left; else m1 := row_buf(x_cnt); end if;
                            if bottom_left > pixel_in then m2 := bottom_left; else m2 := pixel_in; end if;
                            if m1 > m2 then m_final := m1; else m_final := m2; end if;

                            max_out <= m_final;
                            valid_out <= '1';
                        end if;
                    end if;

                    -- Update Coordinates safely
                    if x_cnt = IMAGE_WIDTH - 1 then
                        x_cnt <= 0;
                        if y_cnt = IMAGE_WIDTH - 1 then
                            y_cnt <= 0;
                        else
                            y_cnt <= y_cnt + 1;
                        end if;
                    else
                        x_cnt <= x_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
end Behavioral;