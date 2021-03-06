# dstat2graphs

This is a web application which draws graphs from a dstat CSV file. It accepts the file only output by the following options.

    $ dstat -tvfn --output log.csv 1

## Sample

You can use the demo site below.

- [dstat2graphs - dbstudy.info](http://dbstudy.info/dstat2graphs/)

Here is a sample output.

- [k02c5 2012/05/04 20:03:53 - dstat2graphs](http://dbstudy.info/dstat2graphs/reports/20140309-132019_rbntbQci/)

When you use the demo site, please be aware of the following.

- A CSV file size that can be uploaded is limited to 4MBytes.
- Since there is no access control, please do not upload sensitive data.

## Setup

This tool is intended to be used in Red Hat Enterprise Linux 6 and its clone distributions.

This tool requires Apache HTTP Server and PHP. Please install 'Web Server' and 'PHP Support' package groups.

    # yum groupinstall 'Web Server' 'PHP Support'

Next, please install the following packages.

- perl-Archive-Zip
- rrdtool
- rrdtool-perl

<!-- dummy comment line for breaking list -->

    # yum install perl-Archive-Zip rrdtool rrdtool-perl

This tool uses '/dev/shm' as a working directory. Please create the working directory and give write permission to user 'apache'. If you want to use this tool permanently, please add such procedures to '/etc/rc.local'.

    # mkdir /dev/shm/dstat2graphs
    # chown apache:apache /dev/shm/dstat2graphs

Please place the scripts under the document root of the Apache HTTP Server, create 'reports' directory and give write permission to user 'apache'.

    # mkdir <document_root>/<script_dir>/reports
    # chown apache:apache <document_root>/<script_dir>/reports

If the CSV file size is large, you should modify PHP settings to handle large files. Please adjust parameter 'upload\_max\_filesize' in '/etc/php.ini' to the value greater than the CSV file size. This parameter must meet the relationship 'memory\_limit &gt; post\_max\_size &gt; upload\_max\_filesize'.

    memory_limit = 128M
    post_max_size = 8M
    upload_max_filesize = 2M

## Web UI

If you access http://&lt;server\_host&gt;/&lt;script\_dir&gt;/ in a web browser, the screen will be displayed. When you specify the CSV file and press the Upload button, the graphs will be drawn.

- CSV File
    - CSV File ... Specify the CSV file you want to upload.
- Graph Size
    - Width ... Specify the horizontal size of graphs, in pixel.
    - Height ... Specify the vertical size of graphs, in pixel.
- Upper Limits
    - Disk I/O ... Specify the maximum value of the Y-axis for Disk I/O graphs. The unit is Bytes/second. It is automatically adjusted if you specify 0.
    - Network I/O ... Specify the maximum value of the Y-axis for Network I/O graphs. The unit is Bytes/second. It is automatically adjusted if you specify 0.
- Time Range
    - Offset ... Cut the specified time from the beginning of the CSV file. The unit is second.
    - Duration ... Draw only the specified time from the beginning or the offset position. The unit is second. It draws until the end of the CSV file if you specify 0.

## Perl CUI

It is possible to draw graphs using Perl script 'dstat2graphs.pl'. Please give write permission of '/dev/shm/dstat2graphs' to the user which executes this script. Command line options are as follows. You must specify all.

    $ perl dstat2graph.pl csv_file report_dir width height disk_limit net_limit offset duration

- report_dir ... Specify the directory where you want to store graphs. It is automatically created if it does not exist.

Options other than 'report_dir' are the same as those that can be specified from Web UI.
