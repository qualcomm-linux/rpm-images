# packages/

Place locally built RPMs here before running `make image` (or `make flash`).

## Typical use: custom kernel

```bash
# Copy the kernel RPMs built by scripts/build_binrpm_pkg.py
cp linux/rpmbuild/RPMS/aarch64/kernel-*.rpm packages/

# Build the image (createrepo_c is run automatically)
make flash
```

## Cleanup

To remove the generated `repodata/` index (e.g. after swapping in new RPMs):

```bash
make clean-cache
```
