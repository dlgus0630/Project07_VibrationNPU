#!/usr/bin/env python3
"""LOCAL PC UART logger; MATLAB Online never accesses the serial port."""
import argparse,csv,time
from pathlib import Path
def main():
    p=argparse.ArgumentParser();p.add_argument('--port',required=True);p.add_argument('--command',choices=list('risdb'),default='r')
    p.add_argument('--seconds',type=float,default=10);p.add_argument('--output',default='reports/uart_capture.csv');a=p.parse_args()
    import serial
    out=Path(a.output);out.parent.mkdir(parents=True,exist_ok=True)
    with serial.Serial(a.port,115200,timeout=.2) as ser,out.open('w',newline='') as f:
        writer=csv.writer(f);writer.writerow(['host_time_s','line'])
        ser.reset_input_buffer();ser.write(a.command.encode('ascii'));deadline=time.monotonic()+a.seconds
        while time.monotonic()<deadline:
            line=ser.readline().decode('ascii',errors='replace').strip()
            if line:print(line);writer.writerow([f'{time.time():.6f}',line]);f.flush()
    print(out)
if __name__=='__main__':main()
