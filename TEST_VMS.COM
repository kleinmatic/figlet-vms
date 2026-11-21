$! TEST_VMS.COM - Self-contained OpenVMS Alpha verification suite for FIGlet
$!
$! Usage:
$!   $ @BUILD_VMS
$!   $ @TEST_VMS
$!
$! Prints one PASS or FAIL line per check and a final summary count.
$! Requires no privileges and no setup: FIGLET.EXE is run as a foreign
$! command and finds its fonts from its own location. Uses only top-level DCL labels and cleans up all
$! temporary files in SYS$SCRATCH: on normal exit, error, or CTRL/Y.
$!
$ SAVE_VERIFY = 'F$VERIFY(0)'
$ ON CONTROL_Y THEN GOTO ABORT_EXIT
$ SET NOON
$!
$ PROC_FILE = F$ENVIRONMENT("PROCEDURE")
$ SRC_DIR = F$PARSE(PROC_FILE, , , "DEVICE") + F$PARSE(PROC_FILE, , , "DIRECTORY")
$ FONT_DIR = (SRC_DIR - "]") + ".FONTS]"
$ TEST_DIR = (SRC_DIR - "]") + ".TESTS]"
$!
$ FIGLET_EXE = "$" + SRC_DIR + "FIGLET.EXE"
$ CHKFONT_EXE = "$" + SRC_DIR + "CHKFONT.EXE"
$!
$ PID = F$GETJPI("", "PID")
$ TMP_PFX = "SYS$SCRATCH:FIGTST_" + PID + "_"
$ CAL1 = TMP_PFX + "CAL1.TXT"
$ CAL2 = TMP_PFX + "CAL2.TXT"
$ PROBE_C = TMP_PFX + "PROBE.C"
$ PROBE_OBJ = TMP_PFX + "PROBE.OBJ"
$ PROBE_EXE = TMP_PFX + "PROBE.EXE"
$ EOL_C = TMP_PFX + "EOL.C"
$ EOL_OBJ = TMP_PFX + "EOL.OBJ"
$ EOL_EXE = TMP_PFX + "EOL.EXE"
$ EOL_CMD = "$" + EOL_EXE
$ IN_TXT = TMP_PFX + "IN.TXT"
$ OUT1 = TMP_PFX + "OUT1.TXT"
$ OUT2 = TMP_PFX + "OUT2.TXT"
$ VAR_FDL = TMP_PFX + "VAR.FDL"
$ VAR_FLF = TMP_PFX + "VAR.FLF"
$ LF_FLF = TMP_PFX + "LF.FLF"
$ CRLF_FLF = TMP_PFX + "CRLF.FLF"
$!
$ REF_STD = TEST_DIR + "VMS_STD.TXT"
$ REF_SLANT = TEST_DIR + "VMS_SLANT.TXT"
$ REF_QUOTE = TEST_DIR + "VMS_QUOTE.TXT"
$!
$ PASS_CNT = 0
$ FAIL_CNT = 0
$ DIF_SAME = 0
$ DIF_DIFF = 0
$!
$! ============================================================================
$! Calibrate DIFFERENCES status codes for identical vs differing files
$! ============================================================================
$ IF F$SEARCH(CAL1) .NES. "" THEN DELETE/NOLOG 'CAL1';*
$ IF F$SEARCH(CAL2) .NES. "" THEN DELETE/NOLOG 'CAL2';*
$ OPEN/WRITE T_IN 'CAL1'
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO HARNESS_FAIL
$ WRITE T_IN "alpha"
$ CLOSE T_IN
$ OPEN/WRITE T_IN 'CAL2'
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO HARNESS_FAIL
$ WRITE T_IN "beta"
$ CLOSE T_IN
$ DIFFERENCES/OUTPUT=NL: 'CAL1' 'CAL1'
$ DIF_SAME = $STATUS
$ DIFFERENCES/OUTPUT=NL: 'CAL1' 'CAL2'
$ DIF_DIFF = $STATUS
$!
$ WRITE SYS$OUTPUT "FIGlet OpenVMS Alpha Test Suite"
$ WRITE SYS$OUTPUT "  Source dir:   ", SRC_DIR
$ WRITE SYS$OUTPUT "  Font dir:     ", FONT_DIR
$ WRITE SYS$OUTPUT "  DIF_SAME:     ", F$FAO("!XL", F$INTEGER(DIF_SAME))
$ WRITE SYS$OUTPUT "  DIF_DIFF:     ", F$FAO("!XL", F$INTEGER(DIF_DIFF))
$ WRITE SYS$OUTPUT ""
$!
$ IF DIF_SAME .EQ. DIF_DIFF THEN GOTO HARNESS_FAIL
$ GOTO CHECK_A
$!
$ HARNESS_FAIL:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL harness. DIFFERENCES calibration failed (DIF_SAME=", -
    F$FAO("!XL", F$INTEGER(DIF_SAME)), ", DIF_DIFF=", F$FAO("!XL", F$INTEGER(DIF_DIFF)), ")"
$ GOTO SUMMARY
$!
$! ============================================================================
$! Check a: C compiler/CRTL probe (__STDC__, sizeof(wchar_t), EXIT_*)
$! ============================================================================
$ CHECK_A:
$ OPEN/WRITE T_SRC 'PROBE_C'
$ IF .NOT. $STATUS THEN GOTO FAIL_A
$ WRITE T_SRC "#include <stdio.h>"
$ WRITE T_SRC "#include <stdlib.h>"
$ WRITE T_SRC "#include <wchar.h>"
$ WRITE T_SRC "int main(void) {"
$ WRITE T_SRC "#ifdef __STDC__"
$ WRITE T_SRC "  printf(""__STDC__=defined(%d) "", (int)__STDC__);"
$ WRITE T_SRC "#else"
$ WRITE T_SRC "  printf(""__STDC__=undefined "");"
$ WRITE T_SRC "#endif"
$ WRITE T_SRC "  printf(""sizeof(wchar_t)=%u EXIT_SUCCESS=%d EXIT_FAILURE=%d (0x%x)\n"","
$ WRITE T_SRC "    (unsigned)sizeof(wchar_t), EXIT_SUCCESS, EXIT_FAILURE,"
$ WRITE T_SRC "    (unsigned)EXIT_FAILURE);"
$ WRITE T_SRC "  return EXIT_SUCCESS;"
$ WRITE T_SRC "}"
$ CLOSE T_SRC
$!
$ CC/PREFIX=ALL /OBJECT='PROBE_OBJ' 'PROBE_C'
$ IF .NOT. $STATUS THEN GOTO FAIL_A
$ LINK /EXECUTABLE='PROBE_EXE' 'PROBE_OBJ'
$ IF .NOT. $STATUS THEN GOTO FAIL_A
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT1'"
$ RUN 'PROBE_EXE'
$ IF .NOT. $STATUS THEN GOTO FAIL_A
$ PROBE_LINE = ""
$ OPEN/READ T_OUT 'OUT1'
$ READ/END_OF_FILE=PROBE_EOF T_OUT PROBE_LINE
$ PROBE_EOF:
$ CLOSE T_OUT
$ IF PROBE_LINE .EQS. "" THEN GOTO FAIL_A
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS a. C probe: ", PROBE_LINE
$ GOTO CHECK_B
$ FAIL_A:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL a. C probe compile/link/run failed"
$!
$! ============================================================================
$! Check b: FIGLET "Hello" returns success status ($STATUS is odd)
$! ============================================================================
$ CHECK_B:
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT1'"
$ FIGLET_EXE "Hello"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_B
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS b. FIGLET ""Hello"" returned success status (", F$FAO("!XL", F$INTEGER(ST)), ")"
$ GOTO CHECK_C
$ FAIL_B:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL b. FIGLET ""Hello"" returned non-success status (", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check c: FIGLET /FONT=NOSUCHFONT x returns failure status ($STATUS is even)
$! ============================================================================
$ CHECK_C:
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT NL:
$ DEFINE/USER_MODE/NOLOG SYS$ERROR NL:
$ FIGLET_EXE /FONT=NOSUCHFONT x
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 0 THEN GOTO FAIL_C
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS c. FIGLET /FONT=NOSUCHFONT returned failure status (", F$FAO("!XL", F$INTEGER(ST)), ")"
$ GOTO CHECK_D1
$ FAIL_C:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL c. FIGLET /FONT=NOSUCHFONT returned success status (", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check d1: /OUTPUT file matches reference for standard font
$! ============================================================================
$ CHECK_D1:
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ FIGLET_EXE /FONT=STANDARD /OUTPUT='OUT1' "Hello, OpenVMS!"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_D1
$ CMP_A = OUT1
$ CMP_B = REF_STD
$ GOSUB COMPARE_FILES
$ IF CMP_OK .NE. 1 THEN GOTO FAIL_D1
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS d1. standard font output matches [.TESTS]VMS_STD.TXT"
$ GOTO CHECK_D2
$ FAIL_D1:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL d1. standard font output mismatch (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check d2: DEFINE/USER_MODE SYS$OUTPUT matches reference for slant font
$! ============================================================================
$ CHECK_D2:
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT1'"
$ FIGLET_EXE /FONT=SLANT "Hello, OpenVMS!"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_D2
$ CMP_A = OUT1
$ CMP_B = REF_SLANT
$ GOSUB COMPARE_FILES
$ IF CMP_OK .NE. 1 THEN GOTO FAIL_D2
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS d2. slant font output matches [.TESTS]VMS_SLANT.TXT"
$ GOTO CHECK_D3
$ FAIL_D2:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL d2. slant font output mismatch (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check d3: RFM=VAR font (via CONVERT/FDL) matches reference for slant font
$! ============================================================================
$ CHECK_D3:
$ IF F$SEARCH(VAR_FDL) .NES. "" THEN DELETE/NOLOG 'VAR_FDL';*
$ IF F$SEARCH(VAR_FLF) .NES. "" THEN DELETE/NOLOG 'VAR_FLF';*
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ OPEN/WRITE T_SRC 'VAR_FDL'
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_D3
$ WRITE T_SRC "RECORD"
$ WRITE T_SRC "    FORMAT VARIABLE"
$ WRITE T_SRC "    CARRIAGE_CONTROL CARRIAGE_RETURN"
$ CLOSE T_SRC
$ CONVERT/FDL='VAR_FDL' 'FONT_DIR'SLANT.FLF 'VAR_FLF'
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_D3
$ IF F$FILE_ATTRIBUTES(VAR_FLF, "RFM") .NES. "VAR" THEN GOTO FAIL_D3
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT1'"
$ FIGLET_EXE /FONT='VAR_FLF' "Hello, OpenVMS!"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_D3
$ CMP_A = OUT1
$ CMP_B = REF_SLANT
$ GOSUB COMPARE_FILES
$ IF CMP_OK .NE. 1 THEN GOTO FAIL_D3
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS d3. RFM=VAR converted slant font matches [.TESTS]VMS_SLANT.TXT"
$ GOTO CHECK_E
$ FAIL_D3:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL d3. RFM=VAR converted slant font mismatch (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check e: SYS$INPUT and /INPUT match command-line text output
$! ============================================================================
$ CHECK_E:
$ IF F$SEARCH(IN_TXT) .NES. "" THEN DELETE/NOLOG 'IN_TXT';*
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ IF F$SEARCH(OUT2) .NES. "" THEN DELETE/NOLOG 'OUT2';*
$ OPEN/WRITE T_IN 'IN_TXT'
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_E
$ WRITE T_IN "Hello, OpenVMS!"
$ CLOSE T_IN
$ DEFINE/USER_MODE/NOLOG SYS$INPUT "''IN_TXT'"
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT1'"
$ FIGLET_EXE
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_E
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT2'"
$ FIGLET_EXE "Hello, OpenVMS!"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_E
$ CMP_A = OUT1
$ CMP_B = OUT2
$ GOSUB COMPARE_FILES
$ IF CMP_OK .NE. 1 THEN GOTO FAIL_E
$ DELETE/NOLOG 'OUT1';*
$ FIGLET_EXE /INPUT='IN_TXT' /OUTPUT='OUT1'
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_E
$ GOSUB COMPARE_FILES
$ IF CMP_OK .NE. 1 THEN GOTO FAIL_E
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS e. SYS$INPUT and /INPUT match command-line input"
$ GOTO CHECK_F
$ FAIL_E:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL e. SYS$INPUT or /INPUT mismatch (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check f: FIGLET /INFO=2 and /INFO=3 print font dir and default font.
$! The font dir must be found with no logical name and no setup.
$! ============================================================================
$ CHECK_F:
$ GOT_I2 = ""
$ GOT_I3 = ""
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT1'"
$ FIGLET_EXE /INFO=2
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_F
$ OPEN/READ T_OUT 'OUT1'
$ READ/END_OF_FILE=I2_EOF T_OUT GOT_I2
$ I2_EOF:
$ CLOSE T_OUT
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT1'"
$ FIGLET_EXE /INFO=3
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_F
$ OPEN/READ T_OUT 'OUT1'
$ READ/END_OF_FILE=I3_EOF T_OUT GOT_I3
$ I3_EOF:
$ CLOSE T_OUT
$ IF GOT_I2 .EQS. "" THEN GOTO FAIL_F
$ IF F$SEARCH(GOT_I2 + "STANDARD.FLF") .EQS. "" THEN GOTO FAIL_F
$ IF GOT_I3 .NES. "standard" THEN GOTO FAIL_F
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS f. FIGLET /INFO=2 = ", GOT_I2, ", /INFO=3 = ", GOT_I3
$ GOTO CHECK_G
$ FAIL_F:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL f. FIGLET /INFO=2 or /INFO=3 mismatch (got '", GOT_I2, "' / '", GOT_I3, "')"
$!
$! ============================================================================
$! Check g: CHKFONT reports no errors on a clean bundled font
$! Note: Uses SLANT.FLF because upstream standard.flf has a known header
$!       mismatch (Codetag_Cnt 229 vs 230 code-tagged chars from commit 3c3b559).
$! ============================================================================
$ CHECK_G:
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT1'"
$ CHKFONT_EXE 'FONT_DIR'SLANT.FLF
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_G
$ SEARCH/NOOUTPUT 'OUT1' "Errors: 0"
$ ST = $STATUS
$ IF ST .NE. 1 THEN GOTO FAIL_G
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS g. CHKFONT SLANT.FLF reported Errors: 0"
$ GOTO CHECK_H1
$ FAIL_G:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL g. CHKFONT SLANT.FLF check failed (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check h1: FIGLET /LIST runs to completion with success status
$! ============================================================================
$ CHECK_H1:
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ FIGLET_EXE /LIST /OUTPUT='OUT1'
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_H1
$ SEARCH/NOOUTPUT 'OUT1' "standard"
$ ST = $STATUS
$ IF ST .NE. 1 THEN GOTO FAIL_H1
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS h1. FIGLET /LIST completed with success status"
$ GOTO CHECK_H2
$ FAIL_H1:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL h1. FIGLET /LIST failed (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check h2: FIGLET /SAMPLES runs to completion with success status
$! ============================================================================
$ CHECK_H2:
$ IF F$SEARCH(OUT2) .NES. "" THEN DELETE/NOLOG 'OUT2';*
$ FIGLET_EXE /SAMPLES /OUTPUT='OUT2' "VMS"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_H2
$ SEARCH/NOOUTPUT 'OUT2' "slant :"
$ ST = $STATUS
$ IF ST .NE. 1 THEN GOTO FAIL_H2
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS h2. FIGLET /SAMPLES completed with success status"
$ GOTO CHECK_I
$ FAIL_H2:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL h2. FIGLET /SAMPLES failed (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check i: Message containing double quotes renders correctly
$! ============================================================================
$ CHECK_I:
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ FIGLET_EXE /OUTPUT='OUT1' "Say ""Hi"""
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_I
$ CMP_A = OUT1
$ CMP_B = REF_QUOTE
$ GOSUB COMPARE_FILES
$ IF CMP_OK .NE. 1 THEN GOTO FAIL_I
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS i. FIGLET preserved embedded double quotes"
$ GOTO CHECK_J
$ FAIL_I:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL i. FIGLET double-quote output mismatch (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check j: CRLF font copy renders identically to LF font copy
$! ============================================================================
$ CHECK_J:
$ IF F$SEARCH(LF_FLF) .NES. "" THEN DELETE/NOLOG 'LF_FLF';*
$ IF F$SEARCH(CRLF_FLF) .NES. "" THEN DELETE/NOLOG 'CRLF_FLF';*
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ IF F$SEARCH(OUT2) .NES. "" THEN DELETE/NOLOG 'OUT2';*
$ OPEN/WRITE T_SRC 'EOL_C'
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_J
$ WRITE T_SRC "#include <stdio.h>"
$ WRITE T_SRC "#include <stdlib.h>"
$ WRITE T_SRC "int main(int argc, char *argv[]) {"
$ WRITE T_SRC "  FILE *in, *flf, *fcrlf;"
$ WRITE T_SRC "  int c;"
$ WRITE T_SRC "  if (argc < 4) return EXIT_FAILURE;"
$ WRITE T_SRC "  in = fopen(argv[1], ""r"");"
$ WRITE T_SRC "  flf = fopen(argv[2], ""wb"", ""rfm=stmlf"");"
$ WRITE T_SRC "  fcrlf = fopen(argv[3], ""wb"", ""rfm=stmlf"");"
$ WRITE T_SRC "  if (!in || !flf || !fcrlf) return EXIT_FAILURE;"
$ WRITE T_SRC "  while ((c = fgetc(in)) != EOF) {"
$ WRITE T_SRC "    if (c == 13) continue;"
$ WRITE T_SRC "    if (c == 10) {"
$ WRITE T_SRC "      fputc(10, flf);"
$ WRITE T_SRC "      fputc(13, fcrlf);"
$ WRITE T_SRC "      fputc(10, fcrlf);"
$ WRITE T_SRC "    } else {"
$ WRITE T_SRC "      fputc(c, flf);"
$ WRITE T_SRC "      fputc(c, fcrlf);"
$ WRITE T_SRC "    }"
$ WRITE T_SRC "  }"
$ WRITE T_SRC "  fclose(in); fclose(flf); fclose(fcrlf);"
$ WRITE T_SRC "  return EXIT_SUCCESS;"
$ WRITE T_SRC "}"
$ CLOSE T_SRC
$!
$ CC/PREFIX=ALL /OBJECT='EOL_OBJ' 'EOL_C'
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_J
$ LINK /EXECUTABLE='EOL_EXE' 'EOL_OBJ'
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_J
$ EOL_CMD 'FONT_DIR'SLANT.FLF "''LF_FLF'" "''CRLF_FLF'"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_J
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT1'"
$ FIGLET_EXE /FONT='LF_FLF' "Hello, OpenVMS!"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_J
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT2'"
$ FIGLET_EXE /FONT='CRLF_FLF' "Hello, OpenVMS!"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_J
$ CMP_A = OUT1
$ CMP_B = OUT2
$ GOSUB COMPARE_FILES
$ IF CMP_OK .NE. 1 THEN GOTO FAIL_J
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS j. CRLF font copy rendered identically to LF font copy"
$ GOTO CHECK_K
$ FAIL_J:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL j. CRLF vs LF font comparison failed (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check k: Negative control - slant output vs VMS_STD.TXT must report mismatch
$! ============================================================================
$ CHECK_K:
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT "''OUT1'"
$ FIGLET_EXE /FONT=SLANT "Hello, OpenVMS!"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_K
$ CMP_A = OUT1
$ CMP_B = REF_STD
$ GOSUB COMPARE_FILES
$ IF CMP_OK .NE. 0 THEN GOTO FAIL_K
$ IF ST .NE. DIF_DIFF THEN GOTO FAIL_K
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS k. negative control: slant vs [.TESTS]VMS_STD.TXT detected mismatch (", F$FAO("!XL", F$INTEGER(ST)), ")"
$ GOTO CHECK_L
$ FAIL_K:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL k. negative control did not detect expected mismatch (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check l: DCL rules for the message: text without quotation marks becomes
$!          uppercase, and two words are joined with one space
$! ============================================================================
$ CHECK_L:
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ IF F$SEARCH(OUT2) .NES. "" THEN DELETE/NOLOG 'OUT2';*
$ FIGLET_EXE /OUTPUT='OUT1' hello vms
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_L
$ FIGLET_EXE /OUTPUT='OUT2' "HELLO VMS"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_L
$ CMP_A = OUT1
$ CMP_B = OUT2
$ GOSUB COMPARE_FILES
$ IF CMP_OK .NE. 1 THEN GOTO FAIL_L
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS l. message without quotation marks is uppercase"
$ GOTO CHECK_M
$ FAIL_L:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL l. unquoted message check failed (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Check m: qualifiers. An unknown qualifier fails; /JUSTIFY, /WIDTH,
$!          /SPACING, /RIGHT_TO_LEFT and abbreviations are accepted
$! ============================================================================
$ CHECK_M:
$ DEFINE/USER_MODE/NOLOG SYS$OUTPUT NL:
$ DEFINE/USER_MODE/NOLOG SYS$ERROR NL:
$ FIGLET_EXE /NOSUCHQUALIFIER "x"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 0 THEN GOTO FAIL_M
$ IF F$SEARCH(OUT1) .NES. "" THEN DELETE/NOLOG 'OUT1';*
$ FIGLET_EXE /JUSTIFY=CENTER /WIDTH=100 /SPACING=KERN /RIGHT_TO_LEFT /OUTPUT='OUT1' "x"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_M
$ FIGLET_EXE /JUST=RIGHT /NORIGHT /SPAC=FULL /PARA /CONTROL=(UPPER) /OUTPUT='OUT1' "x"
$ ST = $STATUS
$ IF (ST .AND. 1) .NE. 1 THEN GOTO FAIL_M
$ PASS_CNT = PASS_CNT + 1
$ WRITE SYS$OUTPUT "PASS m. qualifiers accepted, unknown qualifier rejected"
$ GOTO SUMMARY
$ FAIL_M:
$ FAIL_CNT = FAIL_CNT + 1
$ WRITE SYS$OUTPUT "FAIL m. qualifier check failed (status=", F$FAO("!XL", F$INTEGER(ST)), ")"
$!
$! ============================================================================
$! Summary & Cleanup
$! ============================================================================
$ SUMMARY:
$ WRITE SYS$OUTPUT ""
$ WRITE SYS$OUTPUT "Summary: ", PASS_CNT, " passed, ", FAIL_CNT, " failed."
$ GOSUB CLEANUP
$ IF FAIL_CNT .NE. 0 THEN EXIT %X10000002 + 0 * F$VERIFY(SAVE_VERIFY)
$ EXIT 1 + 0 * F$VERIFY(SAVE_VERIFY)
$!
$ ABORT_EXIT:
$ WRITE SYS$OUTPUT ""
$ WRITE SYS$OUTPUT "Aborted; cleaning up temporary files..."
$ GOSUB CLEANUP
$ EXIT %X10000004 + 0 * F$VERIFY(SAVE_VERIFY)
$!
$! Subroutine: compare CMP_A and CMP_B via DIFFERENCES; sets ST and CMP_OK (1=match, 0=diff/err)
$ COMPARE_FILES:
$ DIFFERENCES/OUTPUT=NL: 'CMP_A' 'CMP_B'
$ ST = $STATUS
$ CMP_OK = 0
$ IF ST .EQ. DIF_SAME THEN CMP_OK = 1
$ RETURN
$!
$ CLEANUP:
$ IF F$TRNLNM("T_SRC") .NES. "" THEN CLOSE T_SRC
$ IF F$TRNLNM("T_IN") .NES. "" THEN CLOSE T_IN
$ IF F$TRNLNM("T_OUT") .NES. "" THEN CLOSE T_OUT
$ IF F$SEARCH(TMP_PFX + "*.*") .NES. "" THEN DELETE/NOLOG 'TMP_PFX'*.*;*
$ RETURN
