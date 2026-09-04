let () =
  Test_stun.run ();
  Test_srtp.run ();
  Testlib.exit_status ()
