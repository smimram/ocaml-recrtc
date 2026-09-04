let () =
  Test_stun.run ();
  Test_srtp.run ();
  Test_rtp.run ();
  Test_vp8.run ();
  Test_h264.run ();
  Test_matroska.run ();
  Testlib.exit_status ()
