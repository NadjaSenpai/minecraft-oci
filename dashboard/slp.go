package main

// Minecraft Java Server List Ping (SLP) — 自サーバーの公開ポートに TCP で問い合わせ、
// オンライン人数 / 最大人数 / プレイヤー名サンプルを取得する。
// コンソールやログに触れない読み取り専用。

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"time"
)

func writeVarint(buf *bytes.Buffer, value int32) {
	uv := uint32(value)
	for {
		b := byte(uv & 0x7F)
		uv >>= 7
		if uv != 0 {
			buf.WriteByte(b | 0x80)
		} else {
			buf.WriteByte(b)
			return
		}
	}
}

func readVarint(r io.Reader) (int, error) {
	var result uint32
	var shift uint
	var b [1]byte
	for i := 0; i < 5; i++ {
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return 0, err
		}
		result |= uint32(b[0]&0x7F) << shift
		if b[0]&0x80 == 0 {
			return int(result), nil
		}
		shift += 7
	}
	return 0, fmt.Errorf("varint too long")
}

// slpPlayers performs the SLP status handshake and returns online/max counts and
// the player-name sample. The sample may be capped by the server (commonly ~12)
// or disabled; the counts are always accurate.
func slpPlayers(host string, port int) (online, max int, names []string, err error) {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, fmt.Sprintf("%d", port)), 3*time.Second)
	if err != nil {
		return 0, 0, nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))

	// Handshake (next state = 1: status)
	var pkt bytes.Buffer
	writeVarint(&pkt, 0x00) // packet id
	writeVarint(&pkt, -1)   // protocol version (unset for a status ping)
	writeVarint(&pkt, int32(len(host)))
	pkt.WriteString(host)
	_ = binary.Write(&pkt, binary.BigEndian, uint16(port)) // unsigned short, big-endian
	writeVarint(&pkt, 1)
	var frame bytes.Buffer
	writeVarint(&frame, int32(pkt.Len()))
	frame.Write(pkt.Bytes())
	if _, err = conn.Write(frame.Bytes()); err != nil {
		return 0, 0, nil, err
	}

	// Status Request: length(1) + packet id 0x00
	if _, err = conn.Write([]byte{0x01, 0x00}); err != nil {
		return 0, 0, nil, err
	}

	// Status Response: total length, packet id (0x00), then a length-prefixed JSON string.
	if _, err = readVarint(conn); err != nil {
		return 0, 0, nil, err
	}
	pid, err := readVarint(conn)
	if err != nil {
		return 0, 0, nil, err
	}
	if pid != 0x00 {
		return 0, 0, nil, fmt.Errorf("unexpected packet id %d", pid)
	}
	jlen, err := readVarint(conn)
	if err != nil {
		return 0, 0, nil, err
	}
	jbuf := make([]byte, jlen)
	if _, err = io.ReadFull(conn, jbuf); err != nil {
		return 0, 0, nil, err
	}

	var status struct {
		Players struct {
			Max    int `json:"max"`
			Online int `json:"online"`
			Sample []struct {
				Name string `json:"name"`
			} `json:"sample"`
		} `json:"players"`
	}
	if err = json.Unmarshal(jbuf, &status); err != nil {
		return 0, 0, nil, err
	}
	for _, s := range status.Players.Sample {
		names = append(names, s.Name)
	}
	return status.Players.Online, status.Players.Max, names, nil
}
