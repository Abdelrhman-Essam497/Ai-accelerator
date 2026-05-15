library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.cnn_types.all; 

entity cnn_top_level is
    Port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        
        -- SPI Physical Interface
        sclk     : in  std_logic;
        cs       : in  std_logic;
        mosi     : in  std_logic;
        miso     : out std_logic;
        
        -- Status LEDs
        done_led : out std_logic;
        prog_led : out std_logic
    );
end cnn_top_level;

architecture Behavioral of cnn_top_level is

    component spi_slave is
        Port (
            clk, reset, sclk, cs, mosi : in std_logic;
            miso : out std_logic;
            tx_data  : in std_logic_vector(7 downto 0);
            rx_data  : out std_logic_vector(7 downto 0);
            rx_valid : out std_logic;
            busy     : out std_logic
        );
    end component;

    component LineBuffer_3x3 is
        generic ( DATA_WIDTH : integer := 8; IMAGE_WIDTH : integer := 64 );
        port (
            clk, rst, valid_in : in std_logic;
            pixel_in  : in std_logic_vector(7 downto 0);
            window    : out window_3x3;
            valid_out : out std_logic
        );
    end component;

    component conv_mac_3x3 is
        Port (
            clk : in std_logic;
            a11,a12,a13, a21,a22,a23, a31,a32,a33 : in unsigned(7 downto 0);
            w1,w2,w3, w4,w5,w6, w7,w8,w9          : in signed(7 downto 0);
            bias                                  : in signed(7 downto 0);
            result                                : out signed(20 downto 0)
        );
    end component;

    component max_pool_2x2 is
        generic ( DATA_WIDTH : integer := 8; IMAGE_WIDTH : integer := 62 );
        port (
            clk, rst, valid_in : in std_logic;
            pixel_in  : in unsigned(7 downto 0);
            max_out   : out unsigned(7 downto 0);
            valid_out : out std_logic
        );
    end component;

    component bram_8bit is
        generic ( DEPTH : integer := 900 );
        port (
            clk  : in  std_logic;
            we   : in  std_logic;
            addr : in  integer;
            din  : in  std_logic_vector(7 downto 0);
            dout : out std_logic_vector(7 downto 0)
        );
    end component;

    type state_type is (S_IDLE, S_LOAD_WEIGHTS, S_LOAD_IMAGE, S_CONV_PROCESS, S_POOL_PROCESS, S_SEND_RESULTS, S_DONE);
    signal state : state_type := S_IDLE;

    -- ==========================================
    -- IMAGE MEMORY
    -- ==========================================
    type ram_4096_type is array (0 to 4095) of std_logic_vector(7 downto 0);
    signal BRAM_1_IMAGE : ram_4096_type := (others => (others => '0'));
    
    attribute ram_style : string;
    attribute ram_style of BRAM_1_IMAGE : signal is "block";
    
    signal bram1_addr : integer range 0 to 4095 := 0;
    signal bram2_addr : integer range -2 to 3843 := 0;
    signal bram3_addr : integer range 0 to 960  := 0;
    
    -- ==========================================
    -- PARALLEL BRAM INTERCONNECTS
    -- ==========================================
    type byte_array_16 is array (0 to 15) of std_logic_vector(7 downto 0);
    
    signal conv_bram_we   : std_logic_vector(15 downto 0) := (others => '0');
    signal conv_bram_din  : byte_array_16 := (others => (others => '0'));
    signal conv_bram_dout : byte_array_16;

    signal pool_bram_we   : std_logic_vector(15 downto 0) := (others => '0');
    signal pool_bram_din  : byte_array_16 := (others => (others => '0'));
    signal pool_bram_dout : byte_array_16;

    -- ==========================================
    -- SYSTEM SIGNALS
    -- ==========================================
    type weight_matrix is array (0 to 15, 1 to 10) of signed(7 downto 0);
    signal weights : weight_matrix := (others => (others => (others => '0')));
    
    signal weight_filter_idx  : integer range 0 to 15 := 0;
    signal weight_element_idx : integer range 1 to 10 := 1;

    signal spi_rx_data  : std_logic_vector(7 downto 0);
    signal spi_tx_data  : std_logic_vector(7 downto 0);
    signal spi_rx_valid : std_logic;
    
    signal lb_valid_in  : std_logic := '0';
    signal lb_pixel_in  : std_logic_vector(7 downto 0);
    signal lb_window    : window_3x3;
    signal lb_valid_out : std_logic;
    
    type mac_result_array is array (0 to 15) of signed(20 downto 0);
    signal mac_results : mac_result_array;
    signal mac_valid_shift  : std_logic_vector(1 downto 0) := "00";

    signal pool_pixel_in_array  : byte_array_16;
    type pool_out_array is array (0 to 15) of unsigned(7 downto 0);
    signal pool_max_out_array   : pool_out_array;
    
    -- FIXED: Perfect 1-cycle pipeline delay for Pooler
    signal pool_valid_in        : std_logic := '0';
    signal pool_valid_delay     : std_logic := '0'; 
    
    signal pool_valid_out_array : std_logic_vector(15 downto 0);
    signal readout_filter_idx   : integer range 0 to 15 := 0;

begin

    prog_led <= '1';
    spi_tx_data <= pool_bram_dout(readout_filter_idx) when state = S_SEND_RESULTS else (others => '0');

    INST_SPI: spi_slave port map (
        clk => clk, reset => rst, sclk => sclk, cs => cs, mosi => mosi, miso => miso,
        tx_data => spi_tx_data, rx_data => spi_rx_data, rx_valid => spi_rx_valid, busy => open
    );

    INST_LB: LineBuffer_3x3 
        generic map (DATA_WIDTH => 8, IMAGE_WIDTH => 64)
        port map (
            clk => clk, rst => rst, valid_in => lb_valid_in, pixel_in => lb_pixel_in,
            window => lb_window, valid_out => lb_valid_out
        );

    GEN_PARALLEL_BLOCKS: for i in 0 to 15 generate
    
        INST_MAC: conv_mac_3x3 port map (
            clk => clk,
            a11 => unsigned(lb_window(0)(0)), a12 => unsigned(lb_window(0)(1)), a13 => unsigned(lb_window(0)(2)),
            a21 => unsigned(lb_window(1)(0)), a22 => unsigned(lb_window(1)(1)), a23 => unsigned(lb_window(1)(2)),
            a31 => unsigned(lb_window(2)(0)), a32 => unsigned(lb_window(2)(1)), a33 => unsigned(lb_window(2)(2)),
            w1 => weights(i, 1), w2 => weights(i, 2), w3 => weights(i, 3),
            w4 => weights(i, 4), w5 => weights(i, 5), w6 => weights(i, 6),
            w7 => weights(i, 7), w8 => weights(i, 8), w9 => weights(i, 9),
            bias => weights(i, 10),
            result => mac_results(i)
        );

        INST_CONV_BRAM: bram_8bit generic map (DEPTH => 3844)
            port map (clk => clk, we => conv_bram_we(i), addr => bram2_addr, din => conv_bram_din(i), dout => conv_bram_dout(i));

        pool_pixel_in_array(i) <= conv_bram_dout(i);

        INST_POOL: max_pool_2x2 generic map (DATA_WIDTH => 8, IMAGE_WIDTH => 62) 
            port map (clk => clk, rst => rst, valid_in => pool_valid_in, pixel_in => unsigned(pool_pixel_in_array(i)),
                      max_out => pool_max_out_array(i), valid_out => pool_valid_out_array(i));
            
        INST_POOL_BRAM: bram_8bit generic map (DEPTH => 961)
            port map (clk => clk, we => pool_bram_we(i), addr => bram3_addr, din => pool_bram_din(i), dout => pool_bram_dout(i));
            
    end generate GEN_PARALLEL_BLOCKS;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= S_IDLE;
                bram1_addr <= 0; bram2_addr <= -2; bram3_addr <= 0;
                weight_filter_idx <= 0; weight_element_idx <= 1; readout_filter_idx <= 0;
                lb_valid_in <= '0'; pool_valid_in <= '0'; pool_valid_delay <= '0';
                mac_valid_shift <= "00";
                conv_bram_we <= (others => '0'); pool_bram_we <= (others => '0');
                done_led <= '0';
            else
                
                mac_valid_shift(0) <= lb_valid_out;
                mac_valid_shift(1) <= mac_valid_shift(0);
                
                -- FIXED: Apply exactly 1 clock cycle delay to match BRAM read latency
                pool_valid_in <= pool_valid_delay;

                case state is
                
                    when S_IDLE =>
                        if spi_rx_valid = '1' then
                            weights(weight_filter_idx, weight_element_idx) <= signed(spi_rx_data);
                            weight_element_idx <= 2;
                            state <= S_LOAD_WEIGHTS;
                        end if;

                    when S_LOAD_WEIGHTS =>
                        if spi_rx_valid = '1' then
                            weights(weight_filter_idx, weight_element_idx) <= signed(spi_rx_data);
                            if weight_element_idx = 10 then
                                if weight_filter_idx = 15 then
                                    state <= S_LOAD_IMAGE;
                                else
                                    weight_filter_idx <= weight_filter_idx + 1;
                                    weight_element_idx <= 1;
                                end if;
                            else
                                weight_element_idx <= weight_element_idx + 1;
                            end if;
                        end if;

                    when S_LOAD_IMAGE =>
                        if spi_rx_valid = '1' then
                            BRAM_1_IMAGE(bram1_addr) <= spi_rx_data;
                            if bram1_addr = 4095 then
                                state <= S_CONV_PROCESS;
                                bram1_addr <= 0; 
                            else
                                bram1_addr <= bram1_addr + 1;
                            end if;
                        end if;

                   when S_CONV_PROCESS =>
                        if bram1_addr <= 4095 then
                            lb_pixel_in <= BRAM_1_IMAGE(bram1_addr);
                            lb_valid_in <= '1';
                            bram1_addr <= bram1_addr + 1;
                        else
                            lb_valid_in <= '0';
                        end if;

                        -- 1. Trigger the Write Enable
                        if mac_valid_shift(1) = '1' then
                            conv_bram_we <= (others => '1'); 
                            for i in 0 to 15 loop
                                if mac_results(i) < 0 then
                                    conv_bram_din(i) <= (others => '0');
                                elsif mac_results(i) > 255 then
                                    conv_bram_din(i) <= (others => '1');
                                else
                                    conv_bram_din(i) <= std_logic_vector(mac_results(i)(7 downto 0));
                                end if;
                            end loop;
                        else
                            conv_bram_we <= (others => '0');
                        end if;
                        
                        -- 2. Increment Address AFTER the write is triggered
                        if conv_bram_we(0) = '1' then
                            if bram2_addr = 3843 then
                                state <= S_POOL_PROCESS;
                                bram2_addr <= -2;
                            else
                                bram2_addr <= bram2_addr + 1;
                            end if;
                        end if;

                    when S_POOL_PROCESS =>
                        if bram2_addr <= 3843 then
                            pool_valid_delay <= '1';
                            bram2_addr <= bram2_addr + 1;
                        else
                            pool_valid_delay <= '0';
                        end if;

                        -- 1. Trigger the Write Enable
                        if pool_valid_out_array(0) = '1' then
                            pool_bram_we <= (others => '1');
                            for i in 0 to 15 loop
                                pool_bram_din(i) <= std_logic_vector(pool_max_out_array(i));
                            end loop;
                        else
                            pool_bram_we <= (others => '0');
                        end if;
                        
                        -- 2. Increment Address AFTER the write is triggered
                        if pool_bram_we(0) = '1' then
                            if bram3_addr = 960 then
                                state <= S_SEND_RESULTS;
                                bram3_addr <= 0;
                            else
                                bram3_addr <= bram3_addr + 1;
                            end if;
                        end if;
                    when S_SEND_RESULTS =>
                        pool_bram_we <= (others => '0'); -- Ensure Pool BRAM stops writing
                        
                        if spi_rx_valid = '1' then
                            if bram3_addr = 960 then
                                if readout_filter_idx = 15 then
                                    state <= S_DONE;
                                else
                                    readout_filter_idx <= readout_filter_idx + 1;
                                    bram3_addr <= 0;
                                end if;
                            else
                                bram3_addr <= bram3_addr + 1;
                            end if;
                        end if;

                    when S_DONE =>
                        done_led <= '1';
                        
                end case;
            end if;
        end if;
    end process;

end Behavioral;