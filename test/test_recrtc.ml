let () =
  Test_stun.run ();
  Test_srtp.run ();
  Test_rtp.run ();
  Testlib.exit_status ()
