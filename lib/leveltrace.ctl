echo micmode device > /n/speech/ctl
leveltrace /n/speech/level 50 22000 &
leveltrace /n/speechshim/level 50 22000 &
{sleep 2; echo 'The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. How vexingly quick daft zebras jump. The five boxing wizards jump quickly.' > /n/speech/say} &
