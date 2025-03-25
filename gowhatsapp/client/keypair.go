package main

import (
	"go.mau.fi/libsignal/ecc"
	"go.mau.fi/util/random"
	"golang.org/x/crypto/curve25519"
)

type KeyPair struct {
	Pub  *[32]byte
	Priv *[32]byte
}

var _ ecc.ECPublicKeyable

func NewKeyPairFromPrivateKey(priv [32]byte) *KeyPair {
	var kp KeyPair
	kp.Priv = &priv
	var pub [32]byte
	curve25519.ScalarBaseMult(&pub, kp.Priv)
	kp.Pub = &pub
	return &kp
}

func NewKeyPair() *KeyPair {
	priv := *(*[32]byte)(random.Bytes(32))

	priv[0] &= 248
	priv[31] &= 127
	priv[31] |= 64

	return NewKeyPairFromPrivateKey(priv)
}

func (kp *KeyPair) CreateSignedPreKey(keyID uint32) *PreKey {
	newKey := NewPreKey(keyID)
	newKey.Signature = kp.Sign(&newKey.KeyPair)
	return newKey
}

func (kp *KeyPair) Sign(keyToSign *KeyPair) *[64]byte {
	pubKeyForSignature := make([]byte, 33)
	pubKeyForSignature[0] = ecc.DjbType
	copy(pubKeyForSignature[1:], keyToSign.Pub[:])

	signature := ecc.CalculateSignature(ecc.NewDjbECPrivateKey(*kp.Priv), pubKeyForSignature)
	return &signature
}

type PreKey struct {
	KeyPair
	KeyID     uint32
	Signature *[64]byte
}

func NewPreKey(keyID uint32) *PreKey {
	return &PreKey{
		KeyPair: *NewKeyPair(),
		KeyID:   keyID,
	}
}
