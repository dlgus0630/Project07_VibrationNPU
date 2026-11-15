------------------------------------------------------------
-- 공통 정수 형식과 ROM 초기값 읽기 함수
-- 기존 data/*.mem의 twiddle, 가중치, bias, shift를 그대로 읽는다.
------------------------------------------------------------

LIBRARY ieee;
   USE ieee.std_logic_1164.ALL;
   USE ieee.numeric_std.ALL;
   USE std.textio.ALL;
   USE ieee.std_logic_textio.ALL;

PACKAGE vibration_types IS

   SUBTYPE word16 IS signed(15 DOWNTO 0);

   SUBTYPE word8 IS signed(7 DOWNTO 0);

   TYPE signed16_array IS ARRAY(natural RANGE <>) OF word16;

   TYPE signed8_array IS ARRAY(natural RANGE <>) OF word8;

   TYPE signed32_array IS ARRAY(natural RANGE <>) OF signed(31 DOWNTO 0);

   TYPE unsigned8_array IS ARRAY(natural RANGE <>) OF unsigned(7 DOWNTO 0);

   TYPE unsigned32_array IS ARRAY(natural RANGE <>) OF unsigned(31 DOWNTO 0);

   FUNCTION bit_if (
      b : boolean
   ) RETURN std_logic;

   IMPURE FUNCTION load16 (
      name : string;
      count : positive
   ) RETURN signed16_array;

   IMPURE FUNCTION load8 (
      name : string;
      count : positive
   ) RETURN signed8_array;

   IMPURE FUNCTION load32 (
      name : string;
      count : positive
   ) RETURN signed32_array;

   IMPURE FUNCTION load_shifts (
      name : string
   ) RETURN unsigned8_array;

END PACKAGE vibration_types;

PACKAGE BODY vibration_types IS

   FUNCTION bit_if (
      b : boolean
   ) RETURN std_logic IS
   BEGIN

      IF (b) THEN
         RETURN '1';
      ELSE
         RETURN '0';
      END IF;

   END FUNCTION bit_if;

   IMPURE FUNCTION load16 (
      name : string;
      count : positive
   ) RETURN signed16_array IS

      FILE     f : text OPEN READ_MODE IS name;
      VARIABLE l : line;
      VARIABLE v : std_logic_vector(15 DOWNTO 0);
      VARIABLE a : signed16_array(0 TO count - 1);

   BEGIN

      FOR k IN a'RANGE LOOP

         readline(f, l);
         hread(l, v);
         a(k) := signed(v);

      END LOOP;

      RETURN a;

   END FUNCTION load16;

   IMPURE FUNCTION load8 (
      name : string;
      count : positive
   ) RETURN signed8_array IS

      FILE     f : text OPEN READ_MODE IS name;
      VARIABLE l : line;
      VARIABLE v : std_logic_vector(7 DOWNTO 0);
      VARIABLE a : signed8_array(0 TO count - 1);

   BEGIN

      FOR k IN a'RANGE LOOP

         readline(f, l);
         hread(l, v);
         a(k) := signed(v);

      END LOOP;

      RETURN a;

   END FUNCTION load8;

   IMPURE FUNCTION load32 (
      name : string;
      count : positive
   ) RETURN signed32_array IS

      FILE     f : text OPEN READ_MODE IS name;
      VARIABLE l : line;
      VARIABLE v : std_logic_vector(31 DOWNTO 0);
      VARIABLE a : signed32_array(0 TO count - 1);

   BEGIN

      FOR k IN a'RANGE LOOP

         readline(f, l);
         hread(l, v);
         a(k) := signed(v);

      END LOOP;

      RETURN a;

   END FUNCTION load32;

   IMPURE FUNCTION load_shifts (
      name : string
   ) RETURN unsigned8_array IS

      VARIABLE a : unsigned8_array(0 TO 1);
      VARIABLE s : signed8_array(0 TO 1) := load8(name, 2);

   BEGIN

      FOR k IN a'RANGE LOOP

         a(k) := unsigned(s(k));

      END LOOP;

      RETURN a;

   END FUNCTION load_shifts;

END PACKAGE BODY vibration_types;
