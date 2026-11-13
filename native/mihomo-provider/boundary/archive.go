package boundary

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Archive retains sevenzip's contiguous .001, .002, ... volume semantics while
// opening every volume through the configured root. Decoding stays upstream.
type Archive struct {
	files    []*os.File
	sections []*io.SectionReader
	size     int64
}

func OpenArchive(path string) (*Archive, error) {
	a := &Archive{}
	name := path
	for volume := 1; ; volume++ {
		f, err := Open(name)
		if err != nil {
			if volume > 1 && errors.Is(err, os.ErrNotExist) {
				return a, nil
			}
			return nil, errors.Join(err, a.Close())
		}
		a.files = append(a.files, f)
		stat, err := f.Stat()
		if err != nil {
			return nil, errors.Join(err, a.Close())
		}
		a.sections = append(a.sections, io.NewSectionReader(f, 0, stat.Size()))
		a.size += stat.Size()
		if filepath.Ext(path) != ".001" {
			return a, nil
		}
		name = fmt.Sprintf("%s.%03d", strings.TrimSuffix(path, ".001"), volume+1)
	}
}

func (a *Archive) Size() int64 { return a.size }

func (a *Archive) ReadAt(buf []byte, offset int64) (int, error) {
	if offset < 0 {
		return 0, os.ErrInvalid
	}
	total := 0
	for _, section := range a.sections {
		if offset >= section.Size() {
			offset -= section.Size()
			continue
		}
		n, err := section.ReadAt(buf, offset)
		total += n
		buf = buf[n:]
		offset = 0
		if len(buf) == 0 {
			return total, nil
		}
		if err != nil && !errors.Is(err, io.EOF) {
			return total, err
		}
	}
	if len(buf) == 0 {
		return total, nil
	}
	return total, io.EOF
}

func (a *Archive) Close() error {
	var err error
	for _, f := range a.files {
		err = errors.Join(err, f.Close())
	}
	return err
}
