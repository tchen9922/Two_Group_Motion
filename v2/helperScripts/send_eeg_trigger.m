%helper function for sending eeg trigger
function send_eeg_trigger(ioObj, port, trigger)

    io64(ioObj, port, trigger);
    WaitSecs(0.005);
    io64(ioObj, port, 0);

end