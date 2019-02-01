Unf$#!ck My Thinpool
=====================

So you are using Linux LVM with a thinpool and one day (probably after a reboot)
you want to activate the LVs on this thinpool and you get a message about
mismatching `transaction_id`s. None of your thin LVs are accessible. What to do?

Well I'm not exactly sure what to do, but here's what I did anyway. I managed to
recover all data from all thin LVs. Maybe you get lucky too.


Notation
--------

* Name of the volume group: `vg0`
* Name of the thinpool: `vg0/tpool`
* LVM metadata backup is in the file `/etc/lvm/backup/vg0`


Step 1: Try the repair tools
----------------------------

Try to repair the thinpool metadata:

```bash
lvconvert --repair vg0/tpool
```

This creates a "repaired" copy of the thinpool's metadata on a new LV,
`tpool_meta0`. (The original metadata volume is `tpool_tmeta` but it is
hidden, so LVM doesn't let you access it directly.)

You can now try to activate the thinpool again, and LVM will try to
swap in the new metadata for the old one:

```bash
lvchange -aey -v vg0/tpool
```

If you are lucky, your thinpool and its LVs gets activated, and you
are back in business. Congratulations! If not, read on.


Step 2: Extract the data portion of the thinpool
-------------------------------------------------

An LVM thinpool actually consists of two LVs, one for the data portion
and one for the metadata, called `tpool_tdata` and `tpool_tmeta` respectively.
But LVM hides these volumes, and I found no way to access the data portion
without activating the thinpool (which, as mentioned, fails).

So we need to do it manually.  
Find the entry for `tpool_tdata` in the LVM metadata backup.
Hopefully it looks somewhat like this:

```
tpool_tdata {
        [...]
        segment_count = 1

        segment1 {
                start_extent = 0
                extent_count = 20480    # 80 Gigabytes

                type = "striped"
                stripe_count = 1        # linear

                stripes = [
                        "pv0", 8602
                ]
        }
}
```

The `stripes` entry tells you where to find the data portion of your `tpool`
on the physical volume. Here I have only one PV (`pv0`) and the data starts
8602 extents into the PV, having totally `extent_count` = 20480 extents.
The LVM extent size is 4 MiB.

Trial and error has shown that the data portion doesn't start at position
`8602*4MiB` into the PV's block device, but 1 MiB later. YMMV. So to carve out
your `tpool`'s data portion into a file:

```bash
dd if=/dev/path/to/pv0 of=tpool.dat bsize=1M skip=$[1+4*8602] count=$[4*20480]
```

Now `tpool.dat` is an image of your thinpool's data portion.

If your `tpool_tdata` LV is made up of more than one segment... good luck.
Ask someone who knows. Or maybe an educated guess will do.


Step 3: Extract the thinpool's metadata
----------------------------------------

Now we will extract the metadata of the thinpool in a form that we can understand and
process. In contrast to the hidden `tpool_tmeta` LV, the `tpool_meta0` created above by
`lvconvert --repair` is directly accessible, and after activation it can be
dumped with a tool from the `thin-provisioning-tools` package:

```bash
lvchange -ay vg0/tpool_meta0
thin_dump /dev/vg0/tpool_meta0 > tpool_meta0.xml
```

The resulting XML file looks something like this:

```
<superblock uuid="" time="16" transaction="44" data_block_size="128" nr_data_blocks="1310720">
  <device dev_id="3" mapped_blocks="41389" transaction="21" creation_time="5" snap_time="5">
    <single_mapping origin_block="0" data_block="43576" time="5"/>
    <range_mapping origin_begin="16" data_begin="43578" length="67" time="5"/>
    [...]
  </device>
  <device dev_id="5" mapped_blocks="19530" transaction="27" creation_time="8" snap_time="8">
    <single_mapping origin_block="0" data_block="77949" time="8"/>
    <range_mapping origin_begin="1" data_begin="67694" length="4" time="5"/>
    [...]
  </device>
</superblock>
```

The `nr_data_blocks` tells you how many blocks are in the thinpool. How big is a block?
Check the entry for the `tpool` LV in the LVM metadata backup, it should contain a
`chunk_size` entry. In my case this is 128, which means 64 kiB.

How do the blocks from the data portion of `tpool` map to the blocks in the individual
thin LVs? Luckily there's a tool (again from `thin-provisioning-tools`) which outputs
this mapping:

```bash
thin_rmap --region 0..1310720 /dev/vg0/tpool_meta0 > tpool_rmap.txt
```

The given range is based on the `nr_data_blocks` from the `superblock` entry in the above XML file.
The resulting file `tpool_rmap.txt` should look something like this:

```
data 0..1 -> thin(13) 0..1
data 1..2 -> thin(13) 262143..262144
data 2..3 -> thin(11) 3480..3481
[...]
```

Each line is a mapping from the blocks in the data portion of `tpool` to where
they should go in which thin LV (`thin(XX)`). This information is sufficient
to re-assemble the thin LVs!


Step 4: Re-assemble your thin LVs
---------------------------------

Run the script from this repository as follows:

```bash
./thin_unscramble.sh tpool.dat tpool_rmap.txt
```

Files containing the images of the thin LVs will be created in the current
directory, and named `thinXX.dat` where `XX` is the LV's `device_id`.
The LVM metadata backup file should be able to tell you which `device_id`
belongs to which thin LV, at least for those thin LVs that the LVM metadata
knows about. (In my case I got two additional thin LV images, which somehow
got lost from the LVM metadata.)

Note that the thin LV images are sparse, and that their size might be smaller
than the original thin LV. This happens if the final blocks of the thin LV
had never been written to, so no blocks from the thinpool's data portion were
ever mapped to them. For thin LVs that are present in the LVM metadata backup,
you can find their original size from the `extent_count` setting in their LVM
metadata entry. (Remember, one extent is 4 MiB.) Then you can use the
`truncate` command to extend the image size to the proper value.

That's it. Hopefully the images of the thin LVs are sufficient as a starting
point for restoring your data and services. Good luck!

