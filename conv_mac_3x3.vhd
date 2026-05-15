library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity conv_mac_3x3 is
    Port (
        clk : in std_logic;

        -- FIX 1: Pixels from image are naturally unsigned 0-255
        a11,a12,a13 : in unsigned(7 downto 0);
        a21,a22,a23 : in unsigned(7 downto 0);
        a31,a32,a33 : in unsigned(7 downto 0);

        -- FIX 2: Weights and Bias are signed network parameters
        w1,w2,w3 : in signed(7 downto 0);
        w4,w5,w6 : in signed(7 downto 0);
        w7,w8,w9 : in signed(7 downto 0);
        bias     : in signed(7 downto 0);

        -- Output needs to be at least 21 bits to prevent overflow
        result : out signed(20 downto 0) 
    );
end conv_mac_3x3;

architecture Behavioral of conv_mac_3x3 is

    -- ==========================================
    -- XILINX SYNTHESIS ATTRIBUTE: FORCE DSP48 USAGE
    -- ==========================================
    attribute use_dsp : string;
    attribute use_dsp of Behavioral : architecture is "yes";
    -- ==========================================

    -- Stage 1: Pipeline registers for the 17-bit products
    -- (9-bit signed zero-padded pixel * 8-bit signed weight = 17-bit signed)
    signal p1, p2, p3 : signed(16 downto 0) := (others => '0');
    signal p4, p5, p6 : signed(16 downto 0) := (others => '0');
    signal p7, p8, p9 : signed(16 downto 0) := (others => '0');
    
    -- Stage 2: Pipeline register for the final sum
    signal sum : signed(20 downto 0) := (others => '0');

begin

process(clk)
variable v_sum : signed(20 downto 0);
begin
    if rising_edge(clk) then

        -- STAGE 1: MULTIPLICATION
        -- Zero-extend the unsigned pixel to 9 bits so it stays positive when cast to signed
        p1 <= signed('0' & a11) * w1;
        p2 <= signed('0' & a12) * w2;
        p3 <= signed('0' & a13) * w3;
        
        p4 <= signed('0' & a21) * w4;
        p5 <= signed('0' & a22) * w5;
        p6 <= signed('0' & a23) * w6;
        
        p7 <= signed('0' & a31) * w7;
        p8 <= signed('0' & a32) * w8;
        p9 <= signed('0' & a33) * w9;

        -- STAGE 2: ACCUMULATION (ADDER TREE)
        -- Resize products to 21 bits and add the folded bias
        v_sum := resize(p1, 21) + resize(p2, 21) + resize(p3, 21) +
                 resize(p4, 21) + resize(p5, 21) + resize(p6, 21) +
                 resize(p7, 21) + resize(p8, 21) + resize(p9, 21) +
                 resize(bias, 21);

        -- Shift right by 7 before output
        v_sum := shift_right(v_sum, 7);

        -- Hardware ReLU is handled in Top Level, so we just pass the shifted sum
        sum <= v_sum;

    end if;
end process;

-- Output the final registered sum
result <= sum;

end Behavioral;